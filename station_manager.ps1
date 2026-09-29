<#
    station_manager.ps1
    On-Demand Native WPF Form for Managing Missing/Manual Stations.
#>

Add-Type -AssemblyName PresentationFramework, System.Drawing

$scriptDir   = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = "C:\LOCAL\Scripts\daily-records" }

$stationFile = Join-Path $scriptDir "stations.csv"
$missingLog  = Join-Path $scriptDir "missing_log.txt"

# Read missing stations if available
$missingList = @()
if (Test-Path $missingLog) {
    $missingList = Get-Content -Path $missingLog | Where-Object { $_.Trim().Length -gt 0 }
}

# Build XAML Window
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Weather Station Manager" Height="360" Width="420"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize" Background="#F4F4F9">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="110"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="Add Station to Database" 
                   FontSize="16" FontWeight="Bold" Foreground="#333" Margin="0,0,0,12"/>

        <TextBlock Grid.Row="1" Grid.Column="0" Text="Select Missing:" VerticalAlignment="Center" Margin="0,4"/>
        <ComboBox Name="cmbMissing" Grid.Row="1" Grid.Column="1" Margin="0,4" IsEditable="True"/>

        <TextBlock Grid.Row="2" Grid.Column="0" Text="Station ID:" VerticalAlignment="Center" Margin="0,4"/>
        <TextBox Name="txtCode" Grid.Row="2" Grid.Column="1" Margin="0,4" Padding="3"/>

        <TextBlock Grid.Row="3" Grid.Column="0" Text="Station Name:" VerticalAlignment="Center" Margin="0,4"/>
        <TextBox Name="txtName" Grid.Row="3" Grid.Column="1" Margin="0,4" Padding="3"/>

        <TextBlock Grid.Row="4" Grid.Column="0" Text="Latitude:" VerticalAlignment="Center" Margin="0,4"/>
        <TextBox Name="txtLat" Grid.Row="4" Grid.Column="1" Margin="0,4" Padding="3"/>

        <TextBlock Grid.Row="5" Grid.Column="0" Text="Longitude:" VerticalAlignment="Center" Margin="0,4"/>
        <TextBox Name="txtLon" Grid.Row="5" Grid.Column="1" Margin="0,4" Padding="3"/>

        <StackPanel Grid.Row="6" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
            <Button Name="btnSave" Content="Save Station" Width="100" Height="30" Margin="0,0,10,0" 
                    Background="#007ACC" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
            <Button Name="btnClose" Content="Close" Width="80" Height="30" 
                    Background="#888888" Foreground="White" BorderThickness="0"/>
        </StackPanel>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Element Lookup
$cmbMissing = $window.FindName("cmbMissing")
$txtCode    = $window.FindName("txtCode")
$txtName    = $window.FindName("txtName")
$txtLat     = $window.FindName("txtLat")
$txtLon     = $window.FindName("txtLon")
$btnSave    = $window.FindName("btnSave")
$btnClose   = $window.FindName("btnClose")

# Pre-fill Combobox from missing_log.txt
if ($missingList.Count -gt 0) {
    foreach ($m in $missingList) { [void]$cmbMissing.Items.Add($m) }
    $cmbMissing.SelectedIndex = 0
    $txtCode.Text = $missingList[0]
}

# Auto-populate Station ID textbox when combobox changes
$cmbMissing.add_SelectionChanged({
    if ($cmbMissing.SelectedItem) {
        $txtCode.Text = $cmbMissing.SelectedItem.ToString()
    }
})

# Save Button Click Event
$btnSave.add_Click({
    $code = $txtCode.Text.Trim().ToUpper()
    $name = $txtName.Text.Trim().Replace(',', '')
    $lat  = $txtLat.Text.Trim()
    $lon  = $txtLon.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($code) -or [string]::IsNullOrWhiteSpace($lat) -or [string]::IsNullOrWhiteSpace($lon)) {
        [System.Windows.MessageBox]::Show("Please fill in ID, Latitude, and Longitude.", "Validation Error", "OK", "Warning")
        return
    }

    $csvLine = "$code,$name,$lat,$lon"
    Add-Content -Path $stationFile -Value $csvLine

    # Clear inputs
    $txtCode.Text = ""
    $txtName.Text = ""
    $txtLat.Text  = ""
    $txtLon.Text  = ""

    # Remove added item from combo box
    if ($cmbMissing.Items.Contains($code)) {
        $cmbMissing.Items.Remove($code)
    }

    [System.Windows.MessageBox]::Show("Saved $code to stations.csv!", "Success", "OK", "Information")
})

# Close Button Click Event
$btnClose.add_Click({ $window.Close() })

# Show Window
[void]$window.ShowDialog()