/// Product credential egress for the fixed DeepSeek Anthropic business route.
/// Enabled on 2026-10-26 by explicit maintainer decision; the decision record is
/// kept in docs/engineering/business-egress-review.md. This is a compile-time
/// constant: no setting, environment variable, saved account or guest message
/// can change it at runtime. Every request still requires its own host approval,
/// an actual VM owner and the final lifecycle gate before credentials are read.
package enum BusinessModelActivation {
    package static let credentialEgressEnabled = true
}
