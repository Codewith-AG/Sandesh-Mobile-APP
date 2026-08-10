Remove-Item -Recurse -Force "D:\android-sdk" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "D:\android-sdk" -Force
New-Item -ItemType Directory -Path "D:\android-sdk\cmake" -Force
Copy-Item -Recurse "C:\Android\android-sdk\cmake\*" "D:\android-sdk\cmake\" -ErrorAction SilentlyContinue

$dirs = Get-ChildItem "C:\Android\android-sdk" -Directory | Where-Object { $_.Name -ne 'cmake' }
foreach ($d in $dirs) {
    cmd /c "mklink /J `"D:\android-sdk\$($d.Name)`" `"$($d.FullName)`""
}

$files = Get-ChildItem "C:\Android\android-sdk" -File
foreach ($f in $files) {
    Copy-Item "$($f.FullName)" "D:\android-sdk\" -Force
}
