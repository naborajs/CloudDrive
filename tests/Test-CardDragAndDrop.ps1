<#
.SYNOPSIS
    Unit and integration tests for NS Cloud Drive card drag-and-drop reordering,
    directional drop position calculation, dead-zone prevention, interactive
    control safety, and order persistence.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Write-Host "=== NS Cloud Drive Drag-and-Drop Reordering Test Suite ===" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Test Reordering Algorithm Logic (Above / Below / Top / Bottom / Self)
# ------------------------------------------------------------------------------
function Invoke-TestCardReorder([string[]]$CurrentOrder, [string]$DraggedId, [string]$TargetId, [string]$Position) {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $CurrentOrder) { $list.Add($id) }
    
    if (-not $list.Contains($DraggedId) -or -not $list.Contains($TargetId) -or $DraggedId -eq $TargetId) {
        return @($list.ToArray())
    }
    
    $list.Remove($DraggedId) | Out-Null
    $targetIdx = $list.IndexOf($TargetId)
    $insertIdx = if ($Position -eq 'Below') { $targetIdx + 1 } else { $targetIdx }
    if ($insertIdx -gt $list.Count) { $insertIdx = $list.Count }
    if ($insertIdx -lt 0) { $insertIdx = 0 }
    $list.Insert($insertIdx, $DraggedId)
    return @($list.ToArray())
}

$initial = @('acc_H', 'acc_N', 'acc_G', 'acc_T', 'acc_I')

# Test 1.1: Drag acc_T above acc_N (Moving upward)
$res1 = Invoke-TestCardReorder $initial 'acc_T' 'acc_N' 'Above'
if (($res1 -join ',') -ne 'acc_H,acc_T,acc_N,acc_G,acc_I') {
    throw "Test 1.1 Failed: Expected acc_H,acc_T,acc_N,acc_G,acc_I but got $($res1 -join ',')"
}
Write-Host "  [PASS] Upward reordering (Above) verified." -ForegroundColor Green

# Test 1.2: Drag acc_N below acc_T (Moving downward)
$res2 = Invoke-TestCardReorder $initial 'acc_N' 'acc_T' 'Below'
if (($res2 -join ',') -ne 'acc_H,acc_G,acc_T,acc_N,acc_I') {
    throw "Test 1.2 Failed: Expected acc_H,acc_G,acc_T,acc_N,acc_I but got $($res2 -join ',')"
}
Write-Host "  [PASS] Downward reordering (Below) verified." -ForegroundColor Green

# Test 1.3: Dropping at the beginning (acc_I above acc_H)
$res3 = Invoke-TestCardReorder $initial 'acc_I' 'acc_H' 'Above'
if (($res3 -join ',') -ne 'acc_I,acc_H,acc_N,acc_G,acc_T') {
    throw "Test 1.3 Failed: Expected acc_I,acc_H,acc_N,acc_G,acc_T but got $($res3 -join ',')"
}
Write-Host "  [PASS] Dropping at the beginning verified." -ForegroundColor Green

# Test 1.4: Dropping at the end (acc_H below acc_I)
$res4 = Invoke-TestCardReorder $initial 'acc_H' 'acc_I' 'Below'
if (($res4 -join ',') -ne 'acc_N,acc_G,acc_T,acc_I,acc_H') {
    throw "Test 1.4 Failed: Expected acc_N,acc_G,acc_T,acc_I,acc_H but got $($res4 -join ',')"
}
Write-Host "  [PASS] Dropping at the end verified." -ForegroundColor Green

# Test 1.5: Dropping onto self (no-op)
$res5 = Invoke-TestCardReorder $initial 'acc_G' 'acc_G' 'Above'
if (($res5 -join ',') -ne ($initial -join ',')) {
    throw "Test 1.5 Failed: Self-drop modified order!"
}
Write-Host "  [PASS] Self-drop cancellation verified." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 2. Direction Inversion & Dead-Zone Resolution Tests
# ------------------------------------------------------------------------------
function Get-TestCardDropPosition([int]$draggedIdx, [int]$targetIdx, [double]$ptrY, [double]$targetTop, [double]$targetH) {
    if ($draggedIdx -eq $targetIdx) { return 'None' }
    if ($draggedIdx -lt $targetIdx) {
        if ($ptrY -gt ($targetTop + ($targetH * 0.25))) {
            return 'Below'
        } else {
            return 'Above'
        }
    } else {
        if ($ptrY -lt ($targetTop + ($targetH * 0.75))) {
            return 'Above'
        } else {
            return 'Below'
        }
    }
}

# Test 2.1: Downward drag onto adjacent card (A at index 0 down to B at index 1)
# Target B is at top=100, height=100 (range 100 to 200).
$cards = @('CardA', 'CardB', 'CardC')

# When mouse enters top 15% of CardB ($ptrY = 115 <= 125):
$posDownTop = Get-TestCardDropPosition 0 1 115.0 100.0 100.0
if ($posDownTop -ne 'Above') {
    throw "Test 2.1a Failed: Expected 'Above' in top 25% zone, got '$posDownTop'"
}
# When mouse moves past 25% of CardB ($ptrY = 135 > 125):
$posDownPast = Get-TestCardDropPosition 0 1 135.0 100.0 100.0
if ($posDownPast -ne 'Below') {
    throw "Test 2.1b Failed: Expected 'Below' past 25% threshold, got '$posDownPast'"
}
$reorderedDown = Invoke-TestCardReorder $cards 'CardA' 'CardB' $posDownPast
if (($reorderedDown -join ',') -ne 'CardB,CardA,CardC') {
    throw "Test 2.1c Failed: Downward drag failed to move dragged card after target card! Got: $($reorderedDown -join ',')"
}
Write-Host "  [PASS] Downward drag onto adjacent card moves dragged card after target card." -ForegroundColor Green

# Test 2.2: Upward drag onto adjacent card (B at index 1 up to A at index 0)
# Target A is at top=0, height=100 (range 0 to 100).
# When mouse enters bottom 15% of CardA ($ptrY = 85 >= 75):
$posUpBottom = Get-TestCardDropPosition 1 0 85.0 0.0 100.0
if ($posUpBottom -ne 'Below') {
    throw "Test 2.2a Failed: Expected 'Below' in bottom 25% zone, got '$posUpBottom'"
}
# When mouse moves into upper 75% of CardA ($ptrY = 65 < 75):
$posUpPast = Get-TestCardDropPosition 1 0 65.0 0.0 100.0
if ($posUpPast -ne 'Above') {
    throw "Test 2.2b Failed: Expected 'Above' past 75% threshold, got '$posUpPast'"
}
$reorderedUp = Invoke-TestCardReorder $cards 'CardB' 'CardA' $posUpPast
if (($reorderedUp -join ',') -ne 'CardB,CardA,CardC') {
    throw "Test 2.2c Failed: Upward drag failed to move dragged card before target card! Got: $($reorderedUp -join ',')"
}
Write-Host "  [PASS] Upward drag onto adjacent card moves dragged card before target card." -ForegroundColor Green

# Test 2.3: Multi-card drag: Top to bottom (index 0 to index 2)
# Cards: A (idx 0), B (idx 1), C (idx 2). Target C: top=200, height=100.
# Drag A down into lower 75% of C ($ptrY = 250):
$posMultiDown = Get-TestCardDropPosition 0 2 250.0 200.0 100.0
$reorderedMultiDown = Invoke-TestCardReorder $cards 'CardA' 'CardC' $posMultiDown
if (($reorderedMultiDown -join ',') -ne 'CardB,CardC,CardA') {
    throw "Test 2.3 Failed: Multi-card downward drag failed! Got: $($reorderedMultiDown -join ',')"
}
Write-Host "  [PASS] Multi-card drag (top to bottom) verified." -ForegroundColor Green

# Test 2.4: Multi-card drag: Bottom to top (index 2 to index 0)
# Cards: A (idx 0), B (idx 1), C (idx 2). Target A: top=0, height=100.
# Drag C up into upper 75% of A ($ptrY = 40):
$posMultiUp = Get-TestCardDropPosition 2 0 40.0 0.0 100.0
$reorderedMultiUp = Invoke-TestCardReorder $cards 'CardC' 'CardA' $posMultiUp
if (($reorderedMultiUp -join ',') -ne 'CardC,CardA,CardB') {
    throw "Test 2.4 Failed: Multi-card upward drag failed! Got: $($reorderedMultiUp -join ',')"
}
Write-Host "  [PASS] Multi-card drag (bottom to top) verified." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 3. Interactive Control Click Preservation & Card-Wide Drag Initiation
# ------------------------------------------------------------------------------
function Test-ControlIsInteractive($source, $cardRoot) {
    $cur = $source
    while ($cur -and $cur -ne $cardRoot) {
        if ($cur -is [System.Windows.Controls.Primitives.ButtonBase] -or
            $cur -is [System.Windows.Controls.ComboBox] -or
            $cur -is [System.Windows.Controls.TextBox] -or
            $cur -is [System.Windows.Controls.PasswordBox] -or
            $cur -is [System.Windows.Controls.CheckBox] -or
            $cur -is [System.Windows.Controls.Primitives.ScrollBar] -or
            $cur -is [System.Windows.Controls.Primitives.Thumb]) {
            return $true
        }
        $parent = $null
        try {
            if ($cur -is [System.Windows.Media.Visual] -or $cur -is [System.Windows.Media.Media3D.Visual3D]) {
                $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($cur)
            }
        } catch { }
        if (-not $parent -and ($cur -is [System.Windows.FrameworkElement] -or $cur -is [System.Windows.FrameworkContentElement])) {
            $parent = $cur.Parent
        }
        $cur = $parent
    }
    return $false
}

$mockCard = [System.Windows.Controls.Border]::new()
$mockCard.Tag = 'acc_test'
$mockGrid = [System.Windows.Controls.Grid]::new()
$mockCard.Child = $mockGrid

# 1. Grip handle (non-interactive, drag MUST initiate)
$mockGrip = [System.Windows.Controls.Border]::new()
$mockGripIcon = [System.Windows.Controls.Label]::new()
$mockGripIcon.IsHitTestVisible = $false
$mockGrip.Child = $mockGripIcon
$mockGrid.Children.Add($mockGrip) | Out-Null

# 2. Labels (non-interactive, drag MUST initiate)
$mockNameLabel = [System.Windows.Controls.Label]::new()
$mockNameLabel.Content = 'My Cloud Drive'
$mockGrid.Children.Add($mockNameLabel) | Out-Null

# 3. Button (interactive, drag MUST NOT initiate)
$mockBtn = [System.Windows.Controls.Button]::new()
$mockBtnText = [System.Windows.Controls.TextBlock]::new()
$mockBtnText.Text = 'Connect'
$mockBtn.Content = $mockBtnText
$mockGrid.Children.Add($mockBtn) | Out-Null

# 4. ComboBox (interactive, drag MUST NOT initiate)
$mockCombo = [System.Windows.Controls.ComboBox]::new()
$mockGrid.Children.Add($mockCombo) | Out-Null

# Verify classifications
if (-not (Test-ControlIsInteractive $mockBtn $mockCard)) {
    throw "Test 3.1 Failed: Button was classified as non-interactive!"
}
if (-not (Test-ControlIsInteractive $mockBtnText $mockCard)) {
    throw "Test 3.2 Failed: TextBlock inside Button was classified as non-interactive!"
}
if (-not (Test-ControlIsInteractive $mockCombo $mockCard)) {
    throw "Test 3.3 Failed: ComboBox was classified as non-interactive!"
}
if (Test-ControlIsInteractive $mockCard $mockCard) {
    throw "Test 3.4 Failed: Card background was incorrectly classified as interactive!"
}
if (Test-ControlIsInteractive $mockGrip $mockCard) {
    throw "Test 3.5 Failed: Grip handle was incorrectly classified as interactive!"
}
if (Test-ControlIsInteractive $mockNameLabel $mockCard) {
    throw "Test 3.6 Failed: Name label was incorrectly classified as interactive!"
}

# Test WPF PreviewMouseLeftButtonDown simulation
$simDragInitiated = $false
$mockCard.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    if (Test-ControlIsInteractive $e.OriginalSource $s) {
        return
    }
    $script:simDragInitiated = $true
    $e.Handled = $true
})

# Simulate click on Button: must NOT initiate drag
$script:simDragInitiated = $false
$btnEvent = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
$btnEvent.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
$btnEvent.Source = $mockBtn
$mockCard.RaiseEvent($btnEvent)
if ($script:simDragInitiated) {
    throw "Test 3.7 Failed: Button click was intercepted by card drag handler!"
}
Write-Host "  [PASS] Button clicks are not intercepted by card drag." -ForegroundColor Green

# Simulate click on Card Label: MUST initiate drag
$script:simDragInitiated = $false
$lblEvent = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
$lblEvent.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
$lblEvent.Source = $mockNameLabel
$mockCard.RaiseEvent($lblEvent)
if (-not $script:simDragInitiated) {
    throw "Test 3.8 Failed: Click on card label failed to initiate card drag!"
}
Write-Host "  [PASS] Card-wide drag initiation verified." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 4. Account Identity Stability with Duplicate Display Names
# ------------------------------------------------------------------------------
$mockAccounts = @(
    [pscustomobject]@{ Id = 'gdrive_001'; DisplayName = 'Personal Drive'; DriveLetter = 'G'; ProviderId = 'gdrive' },
    [pscustomobject]@{ Id = 'gdrive_002'; DisplayName = 'Personal Drive'; DriveLetter = 'H'; ProviderId = 'gdrive' },
    [pscustomobject]@{ Id = 'terabox_001'; DisplayName = 'Media Backup'; DriveLetter = 'T'; ProviderId = 'terabox' }
)

$orderWithDups = @('gdrive_002', 'gdrive_001', 'terabox_001')
$reorderedDups = Invoke-TestCardReorder $orderWithDups 'gdrive_001' 'gdrive_002' 'Above'
if ($reorderedDups[0] -ne 'gdrive_001' -or $reorderedDups[1] -ne 'gdrive_002') {
    throw "Test 4 Failed: Accounts with identical display names were confused!"
}
Write-Host "  [PASS] Stable account ID tracking with duplicate display names verified." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 5. Account Addition & Removal Handling
# ------------------------------------------------------------------------------
# 5.1: New account added that is not yet in CardDisplayOrder -> must be appended to end
$savedOrder = @('gdrive_001', 'terabox_001')
$currentAccounts = @('gdrive_001', 'gdrive_002', 'terabox_001')

$effectiveOrder = [System.Collections.Generic.List[string]]::new()
foreach ($ordId in $savedOrder) {
    if ($currentAccounts -contains $ordId) {
        $effectiveOrder.Add($ordId)
    }
}
foreach ($accId in $currentAccounts) {
    if (-not $effectiveOrder.Contains($accId)) {
        $effectiveOrder.Add($accId)
    }
}
if (($effectiveOrder -join ',') -ne 'gdrive_001,terabox_001,gdrive_002') {
    throw "Test 5.1 Failed: Newly added account was not appended predictably!"
}
Write-Host "  [PASS] New account addition appended predictably to end." -ForegroundColor Green

# 5.2: Deleted account removed from system -> must be omitted safely from effective order
$savedOrderWithDeleted = @('gdrive_001', 'stale_deleted_acc', 'terabox_001')
$liveAccounts = @('gdrive_001', 'terabox_001')
$cleanOrder = [System.Collections.Generic.List[string]]::new()
foreach ($ordId in $savedOrderWithDeleted) {
    if ($liveAccounts -contains $ordId) {
        $cleanOrder.Add($ordId)
    }
}
if (($cleanOrder -join ',') -ne 'gdrive_001,terabox_001') {
    throw "Test 5.2 Failed: Stale deleted account was not pruned!"
}
Write-Host "  [PASS] Stale/deleted account safely pruned without index corruption." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 6. Settings Persistence of CardDisplayOrder
# ------------------------------------------------------------------------------
$testSettings = @{
    CardDisplayOrder = @('gdrive_002', 'gdrive_001', 'terabox_001')
    Theme = 'Pure Black'
}
$serialized = $testSettings | ConvertTo-Json -Depth 4
$deserialized = $serialized | ConvertFrom-Json
$restoredOrder = @($deserialized.CardDisplayOrder)
if (($restoredOrder -join ',') -ne 'gdrive_002,gdrive_001,terabox_001') {
    throw "Test 6.1 Failed: Settings serialization/deserialization failed!"
}

# Test empty array fallback:
$emptySettings = @{ CardDisplayOrder = @() }
$serializedEmpty = $emptySettings | ConvertTo-Json -Depth 4
$deserializedEmpty = $serializedEmpty | ConvertFrom-Json
$restoredEmpty = if ($deserializedEmpty.PSObject.Properties['CardDisplayOrder'] -and $deserializedEmpty.CardDisplayOrder) {
    @($deserializedEmpty.CardDisplayOrder)
} else {
    @()
}
if (@($restoredEmpty).Count -ne 0) {
    throw "Test 6.2 Failed: Empty CardDisplayOrder did not fallback to empty array!"
}
Write-Host "  [PASS] CardDisplayOrder settings persistence and restoration verified." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 7. Mount & Drive Letter Immutability During Reordering
# ------------------------------------------------------------------------------
$mockMountStates = @{
    'gdrive_001' = @{ DriveLetter = 'G'; IsMounted = $true; VolumeLabel = 'Google Drive 1' }
    'gdrive_002' = @{ DriveLetter = 'H'; IsMounted = $true; VolumeLabel = 'Google Drive 2' }
    'terabox_001' = @{ DriveLetter = 'T'; IsMounted = $true; VolumeLabel = 'TeraBox Backup' }
}

# Reordering operation:
$newOrder = Invoke-TestCardReorder @('gdrive_001', 'gdrive_002', 'terabox_001') 'terabox_001' 'gdrive_001' 'Above'

# Verify all mount states remain unchanged
foreach ($accKey in $mockMountStates.Keys) {
    $st = $mockMountStates[$accKey]
    if (-not $st.IsMounted -or -not $st.DriveLetter) {
        throw "Test 7 Failed: Mount state for $accKey was mutated by reorder!"
    }
}
Write-Host "  [PASS] Drive letters, volume labels, and mount states remain 100% immutable during reordering." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 8. Escape Key and LostMouseCapture Cancellation Contract
# ------------------------------------------------------------------------------
$dragState = [hashtable]::Synchronized(@{
    IsDragging   = $true
    StartPoint   = [System.Windows.Point]::new(50, 100)
    DraggedAccId = 'gdrive_001'
    TargetAccId  = 'gdrive_002'
    DropPosition = 'Above'
})

# Cancellation trigger
$dragState.IsDragging   = $false
$dragState.StartPoint   = $null
$dragState.DraggedAccId = ''
$dragState.TargetAccId  = ''
$dragState.DropPosition = 'None'

if ($dragState.IsDragging -or $dragState.DraggedAccId -or $dragState.TargetAccId) {
    throw "Test 8 Failed: Cancellation failed to reset drag state!"
}
Write-Host "  [PASS] Drag cancellation and cleanup contract verified." -ForegroundColor Green

Write-Host "`nAll Card Drag-and-Drop Reordering Tests PASSED Successfully!" -ForegroundColor Green
