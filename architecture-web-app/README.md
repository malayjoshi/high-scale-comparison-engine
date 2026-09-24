# Architecture diagram

Open [`index.html`](index.html) in a browser for the current, standalone
architecture view. It uses inline CSS and SVG, so it has no build step,
JavaScript dependency, or network dependency.

The diagram follows the implemented path from Microsoft authentication and
API ingestion through worker processing, durable completion, and the client
callback. Benchmark evidence is shown separately from AWS-managed-service
claims so the portfolio does not overstate what LocalStack proves.
