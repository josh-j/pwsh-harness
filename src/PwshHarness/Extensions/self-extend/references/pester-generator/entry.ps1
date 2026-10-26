{
    param($Harness)
    $Harness.Commands.Add('tests', {
            param($c)
            if (-not $c.State.LastResult -or -not $c.State.LastResult.CodeBlocks.Count) {
                throw 'Generate a block first.'
            }
            [pscustomobject]@{
                Action = 'Send'
                Prompt = "Write meaningful Pester 5 tests, mocking external effects, for this script:`n" +
                $c.State.LastResult.CodeBlocks[0].Code
            }
        }, 'Request tests for the primary generated block.')
}
