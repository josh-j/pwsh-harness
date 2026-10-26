#Requires -Version 7.6
# Message author roles as written in journals and provider requests. The ValidateSet on HarnessMessage.Role repeats these spellings.
enum HarnessRole {
    system
    user
    assistant
}
