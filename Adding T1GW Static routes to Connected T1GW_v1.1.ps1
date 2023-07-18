# PowerShell Script to Add /32 static host route(s) on AVS Connected Tier1GW based User provided .csv spreadsheet with VM IP Addresses 

# Function to get all static routes from the user supplied T1GW
function GetT1GWStaticRoutes {
  param (
    [string]$NSXTMgrURL,
    [pscredential]$nsxcred,
    [string]$Tier1RouterID
  )
  try 
  {
    if($PSVersionTable.PSEdition -eq "Core") {
      Invoke-RestMethod -Uri "https://$NSXTMgrURL/policy/api/v1/infra/tier-1s/$Tier1RouterID/static-routes" -Authentication Basic -Credential $nsxcred -Method Get -ContentType "application/json" -SkipCertificateCheck
    } else{
      Invoke-RestMethod -Uri "https://$NSXTMgrURL/policy/api/v1/infra/tier-1s/$Tier1RouterID/static-routes" -Authentication Basic -Credential $nsxcred -Method Get -ContentType "application/json"
    }
  }
  catch 
  {
    Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
    Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
  }
}

# Function to push/patch static routes to the connected T1GW
function PostT1GWStaticRoutes {
  param (
    [string]$Tier1RouterID,
    [string]$NSXTMgrURL,
    [pscredential]$nsxcred,
    [string]$StaticRoute,
    [string]$NextHop,
    [string]$RouteID,
    [string]$RouteName
  )
  $JSONPayload = @"
    {
        "resource_type":"Infra",
        "children":[
          {
            "resource_type":"ChildTier1",
            "marked_for_delete":"false",
            "Tier1":{
              "resource_type":"Tier1",
              "id":"$Tier1RouterID",
              "children":[
                {
                  "resource_type":"ChildStaticRoutes",
                  "marked_for_delete":false,
                  "StaticRoutes":{
                    "network":"$StaticRoute",
                    "next_hops":[
                      {
                        "ip_address":"$NextHop",
                        "admin_distance":1
                      }
                    ],
                    "resource_type":"StaticRoutes",
                    "id":"$RouteID",
                    "display_name":"$RouteName",
                    "children":[],
                    "marked_for_delete":false
                  }
                }
              ]
            }
          }
        ]
    }
"@
  # REST API Patach request to AVS based NSX-T to deploy the static host route
    try
    {
      if($PSVersionTable.PSEdition -eq "Core") {
       Invoke-RestMethod -Uri "https://$NSXTMgrURL/policy/api/v1/infra.json" -Authentication Basic -Credential $nsxcred -Method Patch -Body $JSONPayload -ContentType "application/json" -SkipCertificateCheck
      } else {
        Invoke-RestMethod -Uri "https://$NSXTMgrURL/policy/api/v1/infra.json" -Authentication Basic -Credential $nsxcred -Method Patch -Body $JSONPayload -ContentType "application/json"
      }
    } 
    catch 
    {
      Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
      Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
    }  
}

# <<<<<<<<<<<<<<   Main code starts here  >>>>>>>>>>>>>

#Import-Module PSExcel

# Defining AVS NSX-T URL, user name and password and other User inputs to probe static routes and push the same onto connected T1GW - comment/uncomment as needed
$nsxurl = [string] (Read-Host -Prompt "Enter your AVS SDDC NSX-T Manager IP Address:")
$nsxusername = [string] (Read-Host -Prompt "Enter your AVS SDDC NSX-T Manager User Name:")
$nsxpassword = [string] (Read-Host -Prompt "Enter your AVS SDDC NSX-T Manager Password:")
$T1GW = [string] (Read-Host -Prompt "Enter your AVS SDDC NSX-T Tier1 Gateway Name:")
$T1GW_NVA_NHOP = [string] (Read-Host -Prompt "Enter your AVS SDDC NSX-T Tier1 Gateway to NVA Next-Hop IP Address(without netmask):")
$FilePath_To_Log = [string] (Read-Host -Prompt "Enter the Full File Path to log AVS SDDC NSX-T Tier1 Gateway Route additions:")
$xlsx_File_Path = [string] (Read-Host -Prompt "Enter the Full File Path (.csv) for Migrated VM List IP Addresses:")

# Defining user name and password for AVS SDDC based NSX-T Manager but this can be changed to receive as a user input
$nsxsecurepassword = ConvertTo-SecureString "$nsxpassword" -AsPlainText -Force
$nsxcred = New-Object System.Management.Automation.PSCredential ("$nsxusername", $nsxsecurepassword)

# Getting the Connected T1GW static route table before updation
$T1GWRoutesData = GetT1GWStaticRoutes -NSXTMgrURL $nsxurl -NSXcred $nsxcred -Tier1RouterID $T1GW 
$T1GWRoutes = $T1GWRoutesData.results

# Importing the list of VM IP addresses from user provided .csv file
$VM_ListData = Import-Csv $xlsx_File_Path

if ($T1GWRoutes.Count -eq 0) # This to cover a use case where there are no static routes in Connected T1GW to start with.
{
    Write-Host ("Connected T1GW Route Table is Empty so adding all VM /32 static routes from the user input .csv file") -ForegroundColor DarkYellow   
    ForEach ($VMs in $VM_ListData)
    {
      $VMIPAddress = $VMs.VMIPAddresses + "/32"
      Write-Host ("{0} : The static route {1} is not present in the connected T1GW Static Route Table, so adding the same to the route table!" -f $(Get-Date), $VMIPAddress) -ForegroundColor DarkGreen
      "{0} : The static route {1} is not present in the connected T1GW Static Route Table, so adding the same to the route table!" -f $(Get-Date), $VMIPAddress | Out-File -FilePath "$FilePath_To_Log" -Append
      PostT1GWStaticRoutes -NSXTMgrURL $nsxurl -NSXcred $nsxcred -Tier1RouterID $T1GW -StaticRoute $VMIPAddress -NextHop $T1GW_NVA_NHOP -RouteID ($VMIPAddress -split '/')[0] -RouteName $VMIPAddress    
    }
}
else 
{
  Write-Host ("The Connected T1GW Route Table before updation is as follows:") -ForegroundColor DarkYellow
  $T1GWRoutes | Format-Table -AutoSize
  ForEach ($VMs in $VM_ListData)
  {
    $VMIPAddress = $VMs.VMIPAddresses + "/32"
    $TotalT1GWRoutes=0

    ForEach ($T1GWRoute in $T1GWRoutes)
    {
      $TotalT1GWRoutes+=1
      if ($VMIPAddress -eq $T1GWRoute.network) # Checking if the /32 static routes are already present in Connected T1GW Route Table
      {
        Write-Host ("The static route {0} is already present in the connected T1GW Static Route Table, so skipping the same" -f $VMIPAddress) -ForegroundColor DarkRed
        $TotalT1GWRoutes=0
        break
      }
      elseif ($TotalT1GWRoutes -eq $T1GWRoutes.Count) #  if the /32 static routes are not present then add the same to Connected T1GW Route Table
      {
        Write-Host ("{0} : The static route {1} is not present in the connected T1GW Static Route Table, so adding the same to the route table!" -f $(Get-Date), $VMIPAddress) -ForegroundColor DarkGreen
        "{0} : The static route {1} is not present in the connected T1GW Static Route Table, so adding the same to the route table!" -f $(Get-Date), $T1GWRoute.network | Out-File -FilePath "$FilePath_To_Log" -Append
        PostT1GWStaticRoutes -NSXTMgrURL $nsxurl -NSXcred $nsxcred -Tier1RouterID $T1GW -StaticRoute $VMIPAddress -NextHop $T1GW_NVA_NHOP -RouteID ($VMIPAddress -split '/')[0] -RouteName $VMIPAddress
        $TotalT1GWRoutes=0
      }
    }
  }
}
# Getting the Connected T1GW static route table after updation
$T1GWRoutesData = GetT1GWStaticRoutes -NSXTMgrURL $nsxurl -NSXcred $nsxcred -Tier1RouterID $T1GW 
$T1GWRoutes = $T1GWRoutesData.results
Write-Host ("The Connected T1GW Route Table after updation is as follows:") -ForegroundColor DarkYellow
$T1GWRoutes | Format-Table -AutoSize
