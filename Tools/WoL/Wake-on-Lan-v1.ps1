# Enable WPF
Add-Type -AssemblyName PresentationCore,PresentationFramework

############################################################################################
                            # Check if computer is online #
############################################################################################
Function Check-Connectivity {
    Param(
        [Parameter(Mandatory=$true)]
        $IpAddress
    )

    Begin {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $byte = [Byte[]](1..32)
        $timeout = 100
    }

    Process {
        $result = $ping.Send($IpAddress,$timeout,$byte)
    }

    End {
        $ping.Dispose()
        Return $result.Status
    }
}

############################################################################################
                      # Check if computer allows remote commands #
############################################################################################
Function Check-RemoteEnable {
    Param(
        [Parameter(Mandatory=$true)]
        $IpAddress
    )

    Begin {
        $socket = [System.Net.Sockets.TcpClient]::new()
    }

    Process {
        Try {
            $socket.Connect($IpAddress, 135)
            $result = $socket.Connected
        }
        Catch {
            $result = $_.exception.message
        }
    }

    End {
        $socket.Close()
        $socket.Dispose()
        Return $result
    }
}

############################################################################################
               # Get information on what network the computer is connected to #
############################################################################################
Function Subnet-Gather {

    # Update the message window
    Update-Message -message "Compiling neighbor data..."

    # flush the dns cache so we get the most current data
    Clear-DnsClientCache

    # who am I and what subnet am I operating from?
    # get the local ip address
    $ip = Get-NetIpAddress -AddressFamily IPv4 -PrefixOrigin Dhcp -InterfaceAlias Ethernet | Select *

    # handy numbers for binary math
    $netMath = @(128,64,32,16,8,4,2,1)

    # first, generate the subnet mask
    $subnetMask = @()
    $n = 0

    For ($i=0;$i -lt $ip.PrefixLength;$i++) {
    
        $octet = $octet + $netMath[$n]

        If ($n -eq 7) {

            $subnetMask += $octet
            $octet = $null
            $n = 0

        }
        Else { $n++ }

    }

    If ($octet) { $subnetMask += $octet }
    If ($subnetMask.Count -lt 4) {
        While($subnetMask.Count -lt 4) {
            $subnetMask += 0
        }
    }

    $subnetMask = $subnetMask -join "."

    # next, generate the wildcard mask
    $hostBits = 32 - $ip.PrefixLength
    $wildcardMask = @()
    $n = 0
    $octet = $null
    [Array]::Reverse($netMath) # invert the array for calculations

    For ($i=0;$i -lt $hostBits;$i++) {
    
        $octet = $octet + $netMath[$n]

        If ($n -eq 7) {

            $wildcardMask += $octet
            $octet = $null
            $n = 0

        }
        Else { $n++ }

    }

    If ($octet) { $wildcardMask += $octet }
    If ($wildcardMask.Count -lt 4) {
        While($wildcardMask.Count -lt 4) {
            $wildcardMask += 0
        }
    }

    # the array is backwards, so we'll fix that
    [Array]::Reverse($wildcardMask)
    $wildcardMask = $wildcardMask -join "."

    # use a binary comparison to calculate the network address
    [String]$localhostAddress = $ip.ipAddress
    $networkAddress = [IpAddress](([IpAddress]$localhostAddress).Address -band ([IpAddress]$subnetMask).Address)

    # using a binary or, calculate the broadcast address
    $broadcastAddress = [IpAddress](([IpAddress]$localhostAddress).Address -bor ([IpAddress]$wildcardMask).Address)

    # finally, we need an array of all the addresses that we
    # would compare against with our DNS query
    $networkBytes = $networkAddress.GetAddressBytes()
    [Array]::Reverse($networkBytes) # the array is inverted for iteration purposes
    $networkINT = [BitConverter]::ToUInt32($networkBytes, 0)

    $broadcastBytes = $broadcastAddress.GetAddressBytes()
    [Array]::Reverse($broadcastBytes)
    $broadcastINT = [BitConverter]::ToUInt32($broadcastBytes, 0)

    $allAddresses = @()
    For ($i = $networkINT + 1; $i -lt $broadcastINT; $i++) {
        $addressBytes = [BitConverter]::GetBytes($i)
        [Array]::Reverse($addressBytes)
        $address = New-Object ipaddress(,$addressBytes)
        $allAddresses += $address
    }

    # get all the DNS records of machines in your subnet
    $logonServer = ([DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().DomainControllers)[0].Name -replace "\.$($env:UserDNSDomain)"
    $dnsRecords = (Get-DnsServerResourceRecord -ZoneName $env:USERDNSDOMAIN -ComputerName $logonServer).Where({
        ($($_.RecordData).IPv4Address -in $allAddresses) -and ($_.HostName -notlike "*$env:USERDNSDOMAIN")}) |
        Select HostName,@{n='IpAddress';e={$($_.RecordData).IPv4Address}},Timestamp
         
    # remove any duplicate records
    $dnsRecords = $dnsRecords | Sort Timestamp -Descending | Group IpAddress | %{$_.Group | Select -First 1} |
        Select HostName,IpAddress | Sort HostName

    $script:dnsData = $dnsRecords

}

############################################################################################
            # Build information on what computers are in the same network #
############################################################################################
Function Mac-Gather {
    
    # check if the "database" exists and declare
    # common use paths
    $MacDatabase = "$env:Temp\MACinfo.csv"
    $errorLog = "$env:Temp\error.txt"

    # if the MAC database exists, make sure we're only
    # looking at computers we don't have entries for yet
    If (Test-Path $MacDatabase) {
        $data = @()
        $MacData = Import-Csv -path $MacDatabase

        ForEach ($entry in $dnsData) {
            If ($entry.HostName -in $MacData.HostName) {
                Continue
            }
            Else {
                $data += $entry
            }
        }
    }
    Else {
        $data = $dnsData
    }
               
    # check to see which computers are available
    # and if they're who they say they are
    # use some runspaces to make this a bit quicker
    $n = 0
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $functionDefA = Get-Content function:\Check-Connectivity
    $functionDefB = Get-Content function:\Check-RemoteEnable
    $functionEntryA = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList "Check-Connectivity",$functionDefA
    $functionEntryB = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList "Check-RemoteEnable",$functionDefB

    # add the local functions to the runspaces
    $initialSessionState.Commands.Add($functionEntryA)
    $initialSessionState.Commands.Add($functionEntryB)

    # create array for monitoring all the runspaces
    $runspaceCollection = @()

    # create runspace pool
    $runspacePool = [RunspaceFactory]::CreateRunspacePool(1,10,$initialSessionState,$host)
    $runspacePool.ApartmentState = "MTA"
    $runspacePool.Open()

    # define what the runspaces are going to do
    $scriptblock = {
        Param(
            $param1,
            $param2
        )

        If ((Check-Connectivity -IpAddress $param1) -eq 'Success') {
            If (Check-RemoteEnable -IpAddress $param1) {
                $result = [pscustomobject]@{
                    Hostname = $param2
                    Status = "Ready"
                }
            }
            Else {
                $result = [pscustomobject]@{
                    Hostname = $param2 
                    Status = "Not Configured"
                }
            }
        }
        Else {
            $result = [pscustomobject]@{
                Hostname = $param2 
                Status = "Offline"
            }
        }

        Return $result

    }

    # finally, make a storage area for all of our results
    $results = [System.Collections.Generic.List[object]]::new()
    
    # let the user know what's going on
    Update-Message -status "Checking computer connectivity..."
    $percent = 1

    # begin working
    While (!$complete) {
    
        If (($runspaceCollection.Count -le 10) -and ($n -lt $data.Count)) {

            $datum = $data[$n]

            $parameters = @{
                param1 = $datum.IpAddress
                param2 = $datum.HostName
            }

            $powershell = [PowerShell]::Create().AddScript($scriptblock).AddParameters($parameters)

            # add the powerhshell job to the pool
            $powershell.RunspacePool = $runspacePool

            # add monitoring to the runspace collection and start the job
            [Collections.ArrayList]$runspaceCollection += New-Object PsObject -Property @{
                Runspace = $powershell.BeginInvoke()
                PowerShell = $powershell
            }

            $n++

        }

        # check the job status and post results
        ForEach ($runspace in $runspaceCollection.ToArray()) {
            If ($runspace.Runspace.IsCompleted) {
                $results.Add($runspace.PowerShell.EndInvoke($runspace.Runspace))

                # dispose of the runspace
                $runspace.PowerShell.Dispose()
                $runspaceCollection.Remove($runspace)

                # update the progress bar
                $progress = [math]::Round(($percent/$data.Count)*100)
                Update-Progress -step $progress
                $percent++
            }
        }

        # define the complete parameters
        If (($n -eq $data.Count) -and ($runspaceCollection.Count -eq 0)){
            $complete = $true
        }

    }

    # grab only the online and ready computers for a filter
    $filter = ($results).Where({$_.Status -eq "Ready"})

    # dump the rest into a variable for later
    $available = $results

    # the runspaces are now going to do something different
    # they will remote to each machine and see if the hostname matches
    $scriptblock = {
        Param(
            $param1,
            $param2
        )

        Try {
            $name = (Get-WmiObject -ComputerName $param1 -Class Win32_ComputerSystem).Name
        }
        Catch {
            $name = $param1
            $macAddress = "Could not verify $param1 identity"
        }

        If ($name -eq $param2) {
        
            Try {
                $macAddress = (Get-WmiObject -Computer $param2 `
                 -Class Win32_NetworkAdapterConfiguration -Filter "DNSDomain='$($env:USERDNSDOMAIN)'").MacAddress[0]
                 # not sure why, but sometimes there are multiple MACs
            }
            Catch {
                $macAddress = "Couldn't retrieve MacAddress"
            }

        }
        Else { 
            $name = $param1
            $macAddress = "does not belong to $param2" 
        }

        $result = [pscustomobject]@{
            HostName = $name
            MacAddress = $macAddress
        }

        Return $result

    }

    # compile a new data array using the filter
    $data = @()
    ForEach ($entry in $dnsData) {
        If ($entry.HostName -in $filter.HostName) {
            $data += $entry
        }
    }

    # reset the counters
    $n = 0
    $complete = $null
    $percent = 1
    Update-Message -status "Compiling MAC list..."
    Update-Progress -step 0

    # a new area to hold the results of the second round
    $results = [System.Collections.Generic.List[object]]::new()

    # begin working
    While (!$complete) {
    
        If (($runspaceCollection.Count -le 10) -and ($n -lt $data.Count)) {

            $datum = $data[$n]

            $parameters = @{
                param1 = $datum.IpAddress
                param2 = $datum.HostName
            }

            $powershell = [powershell]::Create().AddScript($scriptblock).AddParameters($parameters)

            # add the powerhshell job to the pool
            $powershell.RunspacePool = $runspacePool

            # add monitoring to the runspace collection and start the job
            [Collections.ArrayList]$runspaceCollection += New-Object PsObject -Property @{
                Runspace = $powershell.BeginInvoke()
                PowerShell = $powershell
            }

            $n++

        }

        # check the job status and post results
        ForEach ($runspace in $runspaceCollection.ToArray()) {
            If ($runspace.Runspace.IsCompleted) {
                $results.Add($runspace.PowerShell.EndInvoke($runspace.Runspace))

                # dispose of the runspace
                $runspace.PowerShell.Dispose()
                $runspaceCollection.Remove($runspace)

                # update the progress bar
                $progress = [math]::Round(($percent/$data.Count)*100)
                Update-Progress -step $progress
                $percent++
            }
        }

        # define the complete parameters
        If (($n -eq $data.Count) -and ($runspaceCollection.Count -eq 0)){
            $complete = $true
        }

    }

    # filter out the erroneous entries and keep the
    # good ones
    $output = @()
    $errorOut = @()

    ForEach ($result in $results) {

        If ($result.HostName -match '(?:\d{1,3}\.){3}\d{1,3}') {
            $errorOut += $result
        }

        ElseIf ($result.MacAddress -notmatch '^([0-9a-f]{2}:){5}([0-9a-f]{2})$') {
            $errorOut += $result
        }

        Else {
            $output += $result
        }

    }

    # get rid of old entries in the MAC database
    ForEach ($entry in $MacData) {

        If ($entry.HostName -notin $dnsData.HostName) {
            Continue
        }
        Else {
            $output += $entry
        }

    }

    If ($errorOut) {

        Update-Message -status "Fixing some DNS entries..."
        Update-Progress -step 0
        $percent = 1

        ForEach ($entry in $errorOut) {
            Write-Output "Re-registering $($entry.HostName) to DNS"
            ([WmiClass]"\\$($entry.HostName)\ROOT\CIMV2:Win32_Process").Create("cmd.exe /c ipconfig /registerdns")
            $progress = [math]::Round(($percent/$errorOut.Count)*100)
            Update-Progress -step $progress
            $percent++
        }

        $script:available = ($available).Where({$_.HostName -notin $errorOut})
        $errorOut | Out-File $errorLog -Force
    }
    Else {
        $script:available = $available
    }

    $output | Export-Csv $MacDatabase -NoTypeInformation -Append

    # remove the DNS data. We always want the freshest data
    $dnsData = $null

}

############################################################################################
                            # Send a wake-up packet #
############################################################################################
Function Wake-On-LAN {

    Param (
        [CmdletBinding()]
        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [String[]]$mac,
        [String[]]$computer
    )

    # check if input is any of the following types
    # aa:bb:cc:00:11:22
    # aa-bb-cc-00-11-22
    # aabb.cc00.1122
    # aabbcc001122
    $patterns = @(
        '^([0-9a-f]{2}:){5}([0-9a-f]{2})$',
        '^([0-9a-f]{2}-){5}([0-9a-f]{2})$',
        '^([0-9a-f]{4}\.){2}([0-9a-f]{4})$',
        '^([0-9a-f]{12})$'
    )

    If ($mac -notmatch ($patterns -join '|')) {
        Write-Output "Syntax error with MAC"
        Break
    }

    # set the format so there are no special characters
    If ($mac -match '[.-]') {
        $mac = $mac -replace '[.-]'
    }

    # insert colons for a 'proper' MAC address format
    If ($mac -notmatch "[:]") {
        $mac = $mac -replace '(..(?!$))','$1:'
    }


    # create a byte array out of the MAC address
    $macArray = $mac -split ':' | % { [byte] "0x$_" }

    # create a 'magic packet' with the MAC byte array
    # the 'magic packet' MUST contain the MAC address of
    # the destination computer, otherwise WoL will not work
    [Byte[]] $packet = (,0xFF * 6) + ($macArray * 16)

    # WoL uses a UDP client
    $udp = New-Object System.Net.Sockets.UdpClient

    # create a "connection" to the remote device
    # if $computer is specified, try to connect either by DNS name or
    # ip address. Otherwise, a broadcast will be created
    # note: ip/host will only work on Out-of-Band configured devices
    If ($computer) {

        If ($computer -match '(?:\d{1,3}\.){3}\d{1,3}') {
            # parse the ip address into a useable object
            $ip = [System.Net.IpAddress]::Parse($computer)

            # create a 'socket' object
            $socket = [System.Net.IpEndpoint]::new($ip,7)

            # send the 'magic packet' to the socket
            $udp.Send($packet,$packet.length,$socket)
        }
        Else {
            # send the 'magic packet' using the hostname
            $udp.Send($packet,$packet.length,$computer,7)
        }

    }
    Else {
        # everyone in the subnet will get the packet
        $udp.Connect([System.Net.IpAddress]::broadcast,7)
    
        # send the packet 
        $udp.Send($packet,$packet.length)
    }

    # close and dispose of the udp client
    $udp.Close()
    $udp.Dispose()

}

############################################################################################
                                # Create main GUI #
############################################################################################
Function Main-Window {

    [xml]$code = '
        <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" 
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" 
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        x:Name="Window" Title="Wake on LAN" Height="600" Width="680" ShowInTaskbar="True"
        MinHeight="355" MinWidth="475" WindowStartupLocation="CenterScreen">

            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="75"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- First Row -->
                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="auto"/>
                    </Grid.ColumnDefinitions>

                    <Button x:Name="ButtonA" Content="Refresh" Grid.Column="0"
                    HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,10,0"
                    Width="75" Height="30" FontWeight="Bold"/>

                    <Button x:Name="ButtonB" Content="Wake All" Grid.Column="1"
                    HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,10,0"
                    Width="75" Height="30" FontWeight="Bold"/>

                </Grid>

                <!-- Second Row -->
                <Grid Grid.Row="1">
                    <ScrollViewer HorizontalAlignment="Stretch" VerticalAlignment="Stretch"
                    Margin="10,0,10,10">
                        <ItemsControl x:Name="ItemsControl" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                            <ItemsControl.ItemsPanel>
                                <ItemsPanelTemplate>
                                    <WrapPanel />
                                </ItemsPanelTemplate>
                            </ItemsControl.ItemsPanel>
                        </ItemsControl>
                    </ScrollViewer>
                </Grid>
            </Grid>
        </Window>
    '

    $reader = New-Object System.Xml.XmlNodeReader $code
    $window = [Windows.Markup.XamlReader]::Load($reader)

    For ($i = 0; $i -lt $available.count; $i++) {
        $newButton = New-Object System.Windows.Controls.Button
        $newButton.Name    = "Button$i"
        $newButton.Margin  = "2"
        $newButton.Width   = "100"
        $newButton.Height  = "100"

        $newText = New-Object System.Windows.Controls.TextBlock
        $newText.Text         = $($available.HostName)[$i]
        $newText.TextWrapping = "Wrap"
        $newText.FontSize     = 12
        $newText.FontWeight   = "Bold"

        If ($available.Status -eq 'Ready') { 
            $newButton.Background = "Green"
        }
        ElseIf ($available.Status -eq 'Not Configured') {
            $newButton.Background = "Yellow"
        }
        ElseIf ($available.Status -eq 'Offline') {
            $newButton.Background = "Red"
        }            

        $newButton.AddChild($newText)
        $window.FindName('ItemsControl').AddChild($newButton)
    }            

    $window.ShowDialog()
}

############################################################################################
                             # Provide wait screens for user #
############################################################################################
Function Progress-Window {

    Param([int]$Type)

    # Create a new runspace for the boxes to run in
    $global:syncHash = [HashTable]::Synchronized(@{})
    $new_runspace = [RunspaceFactory]::CreateRunspace()
    $new_runspace.ApartmentState = "STA"
    $new_runspace.ThreadOptions = "ReuseThread"
    $new_runspace.Open()
    $new_runspace.SessionStateProxy.SetVariable("syncHash",$syncHash)

    # Define the different boxes
    Switch ($Type) {
        1 {
            $text1 = 'Processing. Please Wait.'
            $text2 = ' '
            $pbar = '<ProgressBar x:Name="PBar" HorizontalAlignment="Center" Width="45" Height="20" IsIndeterminate="True"/>'
        }
        2 {
            $text1 = ' '
            $text2 = '{Binding ElementName=PBar, Path=Value, StringFormat={}{0:0}%}'
            $pbar = '<ProgressBar x:Name="PBar" HorizontalAlignment="Center" Width="220" Height="20" IsIndeterminate="False" Value="0" Maximum="100"/>'
        }
    }

    $parameters = @{
        param1 = $text1
        param2 = $text2
        param3 = $pbar
    }

    # Build the xml as an array to allow variables
    $command = [PowerShell]::Create().AddScript({
        Param($param1,$param2,$param3)

        [Xml]$xml = @(
            '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Wake on LAN" Height="250" Width="270" WindowStartupLocation="CenterScreen" ResizeMode="NoResize">',
            '<Grid>',
            '<StackPanel>',
            "<TextBlock Name=`"Text1`" HorizontalAlignment=`"Center`" Margin=`"0,75,0,5`" Text=`"$param1`"/>",
            $param3,
            "<TextBlock Name=`"Text2`" HorizontalAlignment=`"Center`" Margin=`"0,70,0,5`" Text=`"$param2`"/>",
            '</StackPanel>',
            '</Grid>',
            '</Window>'
        )
         
        # Window Constructor
        $reader = New-Object System.Xml.XmlNodeReader $xml
        $syncHash.Window = [Windows.Markup.XamlReader]::Load($reader)

        # Object identification
        $syncHash.AutoClose = $true
        $syncHash.Progress  = $syncHash.Window.FindName("PBar")
        $syncHash.StatusBox = $syncHash.Window.FindName("Text1")
        $syncHash.InfoBox   = $syncHash.Window.FindName("Text2")

        # Handle the 'X' button
        $syncHash.Window.Add_Closing({
            If ($syncHash.AutoClose -ne $true) {
                $command.EndInvoke($result)
                $command.Runspace.Dispose()
                $command.Runspace.Close()
                $command.Dispose()
                Break
            }
        })

        # Show the window to the user
        [Void]$syncHash.Window.ShowDialog()
        $command.EndInvoke($result)
        $command.Runspace.Dispose()
        $command.Runspace.Close()
        $command.Dispose()
    }).AddParameters($parameters)

    # Create tracking then open the runspace
    $command.Runspace = $new_runspace
    $result = $command.BeginInvoke()

}

############################################################################################
                          # Stop the indeterminent progress window #
############################################################################################
Function Close-Window {
    $syncHash.Window.Dispatcher.Invoke(
        [action]{$syncHash.Window.Close()},"Normal"
    )
}

############################################################################################
                         # Update the bar in the progress window #
############################################################################################
Function Update-Progress ($step) {
    $syncHash.Progress.Dispatcher.Invoke(
        [action]{$syncHash.Progress.Value = $step},"Normal"
    )
}

############################################################################################
                       # Update the message in the progress window #
############################################################################################
Function Update-Message {

    Param(
        [String]$status,
        [String]$message
    )

    Do {
        Start-Sleep -Milliseconds 10
    } Until ($syncHash.StatusBox.Dispatcher -ne $null)

    If ($status){
        $syncHash.StatusBox.Dispatcher.Invoke(
            [action]{$syncHash.StatusBox.Text = $status},"Normal"
        )
    }

    If ($message){
        $syncHash.InfoBox.Dispatcher.Invoke(
            [action]{$syncHash.InfoBox.Text = $message},"Normal"
        )
    }

}

############################################################################################
                       # Single runspace for single wake-up job #
############################################################################################
Function Single-Wakeup {

# Main script
Progress-Window -Type 1
Subnet-Gather
Close-Window
Progress-Window -Type 2
Mac-Gather
Close-Window
Main-Window
