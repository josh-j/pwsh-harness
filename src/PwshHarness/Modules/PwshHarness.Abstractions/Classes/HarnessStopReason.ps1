#Requires -Version 7.6
# Why a bounded agent run ended, spelled exactly as in run summaries and journals.
enum HarnessStopReason {
    Complete
    AwaitingApproval
    Declined
    Cancelled
    StepLimit
    ToolLimit
    TokenLimit
    Deadline
    InputTooLarge
    AuditLimit
    RateLimit
    CostLimit
    StreamStalled
    ProviderStall
    InvalidToolCall
    CallbackFailure
    ProtocolError
    PersistenceFailure
    Reload
}
