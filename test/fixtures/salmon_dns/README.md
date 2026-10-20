The certificate and private key in this directory are synthetic, test-only
fixtures for a local HTTPS server named test.example. They are not deployment
credentials and must never be used in production.

`ca-cert.pem` is a synthetic CA trusted only by the HTTPS success test's
isolated SecurityContext. `test-cert.pem` is its one-year server certificate
with DNS SAN `test.example`, serverAuth EKU, and explicit key usage. The CA
private key is generated temporarily and discarded.

Run `bash test/fixtures/salmon_dns/generate.sh` to refresh both certificates.
The macOS workflow does this before testing so expired fixtures cannot block
later builds. No certificate is installed in the operating system trust store.
The tests also verify rejection of untrusted issuers and mismatched hostnames.
