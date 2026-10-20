{
    param($Harness)
    $Harness.RequestMiddleware.Add('StrictMode', {
            param($request)
            $request.Messages += New-HarnessMessage -Role system -Content 'Begin generated scripts with Set-StrictMode -Version Latest.'
        }, 50)
}
