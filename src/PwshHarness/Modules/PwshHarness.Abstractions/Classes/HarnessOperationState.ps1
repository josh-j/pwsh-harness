#Requires -Version 7.6
# Lifecycle state of a prepared operation as recorded by the host.
enum HarnessOperationState {
    Prepared
    Approved
    Running
    Completed
    Failed
    Cancelled
    Superseded
}
