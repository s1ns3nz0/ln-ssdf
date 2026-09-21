use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use fs2::FileExt;
use lightning_invoice::Bolt11Invoice;
use reqwest::{
    header::{AUTHORIZATION, WWW_AUTHENTICATE},
    Client, StatusCode,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    path::PathBuf,
};

const MAX_REQUEST_SAT: u64 = 50;
const MAX_RUN_SAT: u64 = 100;
const MAX_DAY_SAT: u64 = 200;

#[derive(Parser)]
struct Args {
    #[arg(long)]
    endpoint: Option<String>,
    #[arg(long)]
    subject: Option<String>,
    #[arg(long)]
    serve: bool,
    #[arg(long, default_value = "/state/budget.json")]
    budget_state: PathBuf,
    #[arg(long, default_value = "/lnd/tls.cert")]
    lnd_tls_cert: PathBuf,
    #[arg(long, default_value = "/lnd/admin.macaroon")]
    lnd_macaroon: PathBuf,
    #[arg(long, default_value = "https://lnd-peer-0:8080")]
    lnd_rest_url: String,
}
#[derive(Default, Serialize, Deserialize)]
struct Budget {
    day: String,
    spent_sat: u64,
}

fn event(
    event: &str,
    subject: &str,
    outcome: &str,
    endpoint: &str,
    amount_sat: u64,
    correlation_id: &str,
) {
    // Deliberately fixed allow-list: no challenge, invoice, Authorization header, or preimage can enter evidence.
    println!(
        "{}",
        json!({"event":event,"subject":subject,"outcome":outcome,"endpoint":endpoint,"amount_sat":amount_sat,"correlation_id":correlation_id})
    );
}
fn quoted_parameter(header: &str, name: &str) -> Option<String> {
    header.split(',').find_map(|part| {
        let part = part.trim();
        let (key, value) = part.split_once('=')?;
        (key.trim().trim_start_matches("LSAT ") == name)
            .then(|| value.trim().trim_matches('"').to_string())
    })
}
fn price(invoice: &str) -> Result<u64> {
    // BOLT11 amount parsing is delegated to LND; seller policy is enforced by the route price and payment limit.
    // Reject amountless invoices, which cannot be bounded safely by this client.
    let lower = invoice.to_ascii_lowercase();
    let amount = lower
        .strip_prefix("lnbcrt")
        .or_else(|| lower.strip_prefix("lnbc"))
        .context("unsupported invoice network")?;
    let digits: String = amount.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        bail!("amountless invoice is not permitted");
    }
    let msat = match amount[digits.len()..].chars().next() {
        Some('n') => digits.parse::<u64>()? / 10,
        Some('u') => digits.parse::<u64>()? * 100,
        Some('m') => digits.parse::<u64>()? * 100_000,
        None => digits.parse::<u64>()? * 100_000_000,
        _ => bail!("unsupported invoice amount unit"),
    };
    Ok(msat)
}
fn planned_price(path: &str) -> Result<u64> {
    if path.starts_with("/v1/indicator/") {
        Ok(10)
    } else if path.starts_with("/v1/campaign/") {
        Ok(25)
    } else if path.starts_with("/v1/report/") {
        Ok(50)
    } else {
        bail!("endpoint is not an allowlisted read-only TI product route")
    }
}
fn save_budget(path: &PathBuf, budget: &Budget) -> Result<()> {
    let temporary = path.with_extension("json.next");
    fs::write(&temporary, serde_json::to_vec(budget)?)?;
    fs::rename(temporary, path)?;
    Ok(())
}
async fn pay(client: &Client, args: &Args, invoice: &str) -> Result<String> {
    let macaroon = payment_macaroon(args)?;
    let response = client.post(format!("{}/v2/router/send", args.lnd_rest_url.trim_end_matches('/')))
        .header("Grpc-Metadata-macaroon", macaroon)
        .json(&json!({"payment_request": invoice, "timeout_seconds": 30, "fee_limit_sat": 1, "no_inflight_updates": true}))
        .send().await.context("call lnd-peer payment API")?.error_for_status()?;
    let body = response.text().await.context("read lnd payment result")?;
    settled_preimage(&body)
}
fn payment_macaroon(args: &Args) -> Result<String> {
    Ok(fs::read(&args.lnd_macaroon)
        .context("read restricted payment macaroon")?
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}
fn invoice_payment_hash(invoice: &str) -> Result<String> {
    invoice
        .parse::<Bolt11Invoice>()
        .map_err(|_| anyhow!("decode invoice payment hash"))
        .map(|invoice| invoice.payment_hash().to_string())
}
async fn settled_payment_preimage(
    client: &Client,
    args: &Args,
    payment_hash: &str,
) -> Result<Option<String>> {
    let response = client
        .get(format!(
            "{}/v1/payments?include_incomplete=true",
            args.lnd_rest_url.trim_end_matches('/')
        ))
        .header("Grpc-Metadata-macaroon", payment_macaroon(args)?)
        .send()
        .await
        .context("query lnd payment status")?
        .error_for_status()?;
    let body: Value = response.json().await.context("decode lnd payment status")?;
    Ok(body
        .get("payments")
        .and_then(Value::as_array)
        .and_then(|payments| {
            payments
                .iter()
                .find(|payment| {
                    payment.get("payment_hash").and_then(Value::as_str) == Some(payment_hash)
                        && payment.get("status").and_then(Value::as_str) == Some("SUCCEEDED")
                })
                .and_then(|payment| payment.get("payment_preimage").and_then(Value::as_str))
                .filter(|preimage| !preimage.is_empty())
                .map(str::to_owned)
        }))
}
fn settled_preimage(body: &str) -> Result<String> {
    // SendPaymentV2 is server-streaming. REST gateways emit one JSON envelope
    // per line, with the terminal payment object below `result`; do not retain
    // or report frames because they can contain a preimage.
    let mut saw_failure = false;
    for frame in body.lines().filter(|line| !line.trim().is_empty()) {
        let envelope: Value = serde_json::from_str(frame).context("decode lnd payment result")?;
        let result = envelope.get("result").unwrap_or(&envelope);
        match result.get("status").and_then(Value::as_str) {
            Some("SUCCEEDED") => {
                return result
                    .get("payment_preimage")
                    .and_then(Value::as_str)
                    .filter(|preimage| !preimage.is_empty())
                    .map(str::to_owned)
                    .context("lnd succeeded without a payment preimage");
            }
            Some("FAILED") | Some("FAILURE") => saw_failure = true,
            _ => {}
        }
    }
    if saw_failure {
        bail!("lnd payment failed");
    }
    bail!("lnd did not return a successful final payment result")
}

#[cfg(test)]
mod tests {
    use super::settled_preimage;

    #[test]
    fn accepts_only_a_succeeded_stream_envelope() {
        let stream = "{\"result\":{\"status\":\"IN_FLIGHT\"}}\n{\"result\":{\"status\":\"SUCCEEDED\",\"payment_preimage\":\"01\"}}\n";
        assert_eq!(settled_preimage(stream).unwrap(), "01");
    }

    #[test]
    fn rejects_failed_or_preimage_less_streams_without_echoing_them() {
        assert_eq!(
            settled_preimage(
                "{\"result\":{\"status\":\"FAILED\",\"payment_preimage\":\"secret\"}}"
            )
            .unwrap_err()
            .to_string(),
            "lnd payment failed"
        );
        assert_eq!(
            settled_preimage("{\"result\":{\"status\":\"SUCCEEDED\"}}")
                .unwrap_err()
                .to_string(),
            "lnd succeeded without a payment preimage"
        );
    }
}
#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    if args.serve {
        // The Deployment is an explicitly narrow, idle payment backend. Purchase
        // invocations are exec'd with arguments; it never polls or spends on its own.
        std::future::pending::<()>().await;
        unreachable!();
    }
    let endpoint = args.endpoint.as_deref().context("--endpoint is required")?;
    let subject = args.subject.as_deref().context("--subject is required")?;
    let parsed = url::Url::parse(endpoint)?;
    if parsed.scheme() != "http"
        || parsed.host_str() != Some("aperture.ssdf-system.svc")
        || parsed.port() != Some(8080)
        || parsed.query().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        bail!("endpoint must be the fixed local Aperture service");
    }
    let path = parsed.path();
    let expected_price = planned_price(path)?;
    let correlation_id = format!(
        "p9-{:x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos()
    );
    let lock_path = args.budget_state.with_extension("lock");
    if let Some(parent) = lock_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(lock_path)?;
    lock.try_lock_exclusive()
        .context("another payment is already in progress")?;
    let tls = fs::read(&args.lnd_tls_cert).context("read lnd-peer TLS certificate")?;
    // This is not an insecure TLS bypass: the mounted lnd-peer certificate is
    // the sole private trust anchor and reqwest still verifies its hostname.
    let client = Client::builder()
        .add_root_certificate(reqwest::Certificate::from_pem(&tls)?)
        .build()?;
    let first = client
        .get(endpoint)
        .send()
        .await
        .context("request TI product")?;
    if first.status() == StatusCode::OK {
        event(
            "authorized_access",
            subject,
            "already_authorized",
            path,
            0,
            &correlation_id,
        );
        return Ok(());
    }
    if first.status() != StatusCode::PAYMENT_REQUIRED {
        bail!("expected HTTP 402, got {}", first.status());
    }
    let challenge = first
        .headers()
        .get(WWW_AUTHENTICATE)
        .and_then(|v| v.to_str().ok())
        .context("402 missing WWW-Authenticate")?;
    let invoice =
        quoted_parameter(challenge, "invoice").context("L402 challenge missing invoice")?;
    let token =
        quoted_parameter(challenge, "macaroon").context("L402 challenge missing macaroon")?;
    let amount = price(&invoice)?;
    let payment_hash = invoice_payment_hash(&invoice)?;
    if amount > MAX_REQUEST_SAT || amount > MAX_RUN_SAT {
        bail!("invoice exceeds buyer request/run limit");
    }
    if amount != expected_price {
        bail!("invoice amount differs from the allowlisted product price");
    }
    event(
        "challenge",
        subject,
        "received",
        path,
        amount,
        &correlation_id,
    );
    let today = &chrono_day();
    let mut budget: Budget = fs::read_to_string(&args.budget_state)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    if budget.day != *today {
        budget = Budget {
            day: today.clone(),
            spent_sat: 0,
        };
    }
    if budget.spent_sat.saturating_add(amount) > MAX_DAY_SAT {
        bail!("daily buyer spending limit would be exceeded");
    }
    let preimage = match pay(&client, &args, &invoice).await {
        Ok(preimage) => preimage,
        Err(error) => {
            // A dropped or partial SendPaymentV2 stream is ambiguous. Never
            // retry an invoice until LND history says that payment hash failed.
            match settled_payment_preimage(&client, &args, &payment_hash).await? {
                Some(preimage) => preimage,
                None => {
                    event(
                        "payment_pending",
                        subject,
                        "status_unresolved",
                        path,
                        amount,
                        &correlation_id,
                    );
                    return Err(error.context("lnd payment status unresolved"));
                }
            }
        }
    };
    budget.spent_sat += amount;
    save_budget(&args.budget_state, &budget)?;
    event(
        "settlement",
        subject,
        "settled",
        path,
        amount,
        &correlation_id,
    );
    let authorization = format!("LSAT {}:{}", token, preimage);
    let retry = client
        .get(endpoint)
        .header(AUTHORIZATION, authorization)
        .send()
        .await
        .context("retry paid TI product")?;
    if retry.status() != StatusCode::OK {
        event(
            "failure",
            subject,
            "authorized_retry_failed",
            path,
            amount,
            &correlation_id,
        );
        bail!("authorized retry failed with {}", retry.status());
    }
    event(
        "authorized_access",
        subject,
        "authorized",
        path,
        amount,
        &correlation_id,
    );
    Ok(())
}
fn chrono_day() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| (d.as_secs() / 86_400).to_string())
        .unwrap_or_default()
}
