use std::{
    env, fs,
    net::SocketAddr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
};

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use reqwest::Client;
use serde_json::{json, Value};

#[derive(Clone)]
struct AppState {
    fixture: Arc<Value>,
    authorized: Arc<AtomicU64>,
    failures: Arc<AtomicU64>,
    opencti_url: Option<String>,
    opencti_token: Option<String>,
    client: Client,
}

fn fixture_endpoint(kind: &str, id: &str, state: &AppState) -> Result<Value, StatusCode> {
    let objects = state
        .fixture
        .get("objects")
        .and_then(Value::as_array)
        .ok_or(StatusCode::SERVICE_UNAVAILABLE)?;
    let found = objects
        .iter()
        .find(|object| {
            object.get("type").and_then(Value::as_str) == Some(kind)
                && (object.get("id").and_then(Value::as_str) == Some(id)
                    || object.get("name").and_then(Value::as_str) == Some(id)
                    || object.get("pattern").and_then(Value::as_str) == Some(id))
        })
        .cloned()
        .ok_or(StatusCode::NOT_FOUND)?;
    Ok(json!({"product": found, "source": "public-stix-2.1-fixture"}))
}
async fn endpoint(kind: &str, id: &str, state: &AppState) -> Result<Value, StatusCode> {
    let result = if let Some(url) = &state.opencti_url {
        let query = "query Product($id: ID!) { stixCoreObject(id: $id) { id entity_type name } }";
        let mut request = state
            .client
            .post(url)
            .json(&json!({"query": query, "variables": {"id": id}}));
        if let Some(token) = &state.opencti_token {
            request = request.bearer_auth(token);
        }
        match request
            .send()
            .await
            .and_then(reqwest::Response::error_for_status)
        {
            Ok(response) => response
                .json::<Value>()
                .await
                .map(|data| json!({"product": data, "source": "opencti-graphql"}))
                .map_err(|_| StatusCode::BAD_GATEWAY),
            Err(_) => Err(StatusCode::BAD_GATEWAY),
        }
    } else {
        fixture_endpoint(kind, id, state)
    };
    match result {
        Ok(value) => {
            state.authorized.fetch_add(1, Ordering::Relaxed);
            Ok(value)
        }
        Err(status) => {
            state.failures.fetch_add(1, Ordering::Relaxed);
            Err(status)
        }
    }
}

async fn indicator(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, StatusCode> {
    endpoint("indicator", &id, &state).await.map(Json)
}
async fn campaign(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, StatusCode> {
    endpoint("campaign", &id, &state).await.map(Json)
}
async fn report(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, StatusCode> {
    endpoint("report", &id, &state).await.map(Json)
}
async fn health() -> &'static str {
    "ok\n"
}
async fn metrics(State(state): State<AppState>) -> impl IntoResponse {
    // No request identifiers, headers, documents, or payment material are labels.
    format!("# TYPE ti_product_authorized_accesses_total counter\nti_product_authorized_accesses_total {}\n# TYPE ti_product_failures_total counter\nti_product_failures_total {}\n", state.authorized.load(Ordering::Relaxed), state.failures.load(Ordering::Relaxed))
}

#[tokio::main]
async fn main() {
    let path =
        env::var("STIX_FIXTURE_PATH").unwrap_or_else(|_| "/fixtures/public-stix-2.1.json".into());
    let fixture = match fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
    {
        Some(fixture) => fixture,
        None => {
            eprintln!("TI fixture could not be loaded");
            std::process::exit(1);
        }
    };
    let opencti_url = env::var("OPENCTI_GRAPHQL_URL").ok();
    let opencti_token = env::var("OPENCTI_API_TOKEN_FILE")
        .ok()
        .and_then(|token_path| fs::read_to_string(token_path).ok())
        .map(|token| token.trim().to_owned());
    if opencti_url.is_some() && opencti_token.is_none() {
        eprintln!("OpenCTI token file could not be loaded");
        std::process::exit(1);
    }
    let state = AppState {
        fixture: Arc::new(fixture),
        authorized: Arc::new(AtomicU64::new(0)),
        failures: Arc::new(AtomicU64::new(0)),
        opencti_url,
        opencti_token,
        client: Client::new(),
    };
    let app = Router::new()
        .route("/healthz", get(health))
        .route("/metrics", get(metrics))
        .route("/v1/indicator/:id", get(indicator))
        .route("/v1/campaign/:id", get(campaign))
        .route("/v1/report/:id", get(report))
        .with_state(state);
    let address: SocketAddr = "0.0.0.0:8080".parse().unwrap();
    axum::serve(tokio::net::TcpListener::bind(address).await.unwrap(), app)
        .await
        .unwrap();
}
