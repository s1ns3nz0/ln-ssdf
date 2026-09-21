FROM rust:1.88-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
RUN cargo build --release --locked

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /src/target/release/payment-buyer /usr/local/bin/payment-buyer
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/payment-buyer"]
