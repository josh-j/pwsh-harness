#Requires -Version 7.6
# Outcome of one tool call, spelled as in tool-result envelopes (lowercase on the wire).
enum HarnessToolStatus {
    ok
    error
    cancelled
}
