# synopsis: Inspect names and states of matching Task Scheduler definitions.
# tags: Get-ScheduledTask backup scheduled tasks
Get-ScheduledTask -TaskName '*Backup*' | Select-Object TaskName, State
