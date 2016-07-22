﻿function New-VstsSession {
	param([Parameter()]$AccountName, 
          [Parameter(Mandatory=$true)]$User, 
          [Parameter(Mandatory=$true)]$Token,
		  [Parameter()][string]$Collection = 'DefaultCollection',
		  [Parameter()][string]$Server = 'visualstudio.com',
		  [Parameter()][ValidateSet('HTTP', 'HTTPS')]$Scheme = 'HTTPS'
		  )

	[PSCustomObject]@{
		AccountName = $AccountName
		User = $User
		Token = $Token
		Collection = $Collection
		Server = $Server
		Scheme = $Scheme
	}
}

function Invoke-VstsEndpoint {
    param(
		  [Parameter(Mandatory=$true)]$Session, 
          [Hashtable]$QueryStringParameters, 
          [string]$Project,
          [Uri]$Path, 
          [string]$ApiVersion='1.0', 
          [ValidateSet('GET', 'PUT', 'POST', 'DELETE', 'PATCH')]$Method='GET',
		  [string]$Body)

    $queryString = [System.Web.HttpUtility]::ParseQueryString([string]::Empty)
   
    if ($QueryStringParameters -ne $null)
    {
        foreach($parameter in $QueryStringParameters.GetEnumerator())
        {
            $queryString[$parameter.Key] = $parameter.Value
        }
    }

    $queryString["api-version"] = $ApiVersion
    $queryString = $queryString.ToString();

	$authorization = Get-VstsAuthorization -User $Session.User -Token $Session.Token
	if ([String]::IsNullOrEmpty($Session.AccountName))
	{
		$UriBuilder = New-Object System.UriBuilder -ArgumentList "$($Session.Scheme)://$($Session.Server)"
	}
	else
	{
		$UriBuilder = New-Object System.UriBuilder -ArgumentList "$($Session.Scheme)://$($Session.AccountName).visualstudio.com"
	}
	$Collection = $Session.Collection
	
    $UriBuilder.Query = $queryString
    if ([String]::IsNullOrEmpty($Project))
    {
        $UriBuilder.Path = "$Collection/_apis/$Path"
    }
    else 
    {
        $UriBuilder.Path = "$Collection/$Project/_apis/$Path"
    }

    $Uri = $UriBuilder.Uri

    Write-Verbose "Invoke URI [$uri]"

	$ContentType = 'application/json'
	if ($Method -eq 'PUT' -or $Method -eq 'POST' -or $Method -eq 'PATCH')
	{
		if ($Method -eq 'PATCH')
		{
			$ContentType = 'application/json-patch+json'
		}

		Invoke-RestMethod $Uri -Method $Method -ContentType $ContentType -Headers @{Authorization=$authorization} -Body $Body
	}
	else
	{
		Invoke-RestMethod $Uri -Method $Method -ContentType $ContentType -Headers @{Authorization=$authorization} 
	}
}

function Get-VstsAuthorization {
<#
    .SYNOPSIS
        Generates a VSTS authorization header value from a username and Personal Access Token. 
#>
    param($user, $token)

    $Value = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $user, $token)))
    ("Basic {0}" -f $value)
}

function Get-VstsProject {
<#
    .SYNOPSIS 
        Get projects in a VSTS account.
#>
    param(
		[Parameter(Mandatory, ParameterSetname='Account')]$AccountName, 
		[Parameter(Mandatory, ParameterSetname='Account')]$User, 
		[Parameter(Mandatory, ParameterSetname='Account')]$Token, 
		[Parameter(Mandatory, ParameterSetname='Session')]$Session, 
		[string]$Name)
    
	if ($PSCmdlet.ParameterSetName -eq 'Account')
	{
		$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
	}

	$Value = Invoke-VstsEndpoint -Session $Session -Path 'projects' 

	if ($PSBoundParameters.ContainsKey("Name"))
	{
		$Value.Value | Where Name -eq $Name
	}
	else
	{
		$Value.Value 
	}
}

function Wait-VSTSProject {
	param([Parameter(Mandatory)]$Session, 
	      [Parameter(Mandatory)]$Name, 
		  $Attempts = 30, 
		  [Switch]$Exists)

	$Retries = 0
	do {
		#Takes a few seconds for the project to be created
		Start-Sleep -Seconds 2

		$TeamProject = Get-VSTSProject -Session $Session -Name $Name

		$Retries++
	} while ((($TeamProject -eq $null -and $Exists) -or ($TeamProject -ne $null -and -not $Exists)) -and $Retries -le $Attempts)

	if (($TeamProject -eq $null -and $Exists) -or ($TeamProject -ne $null -and -not $Exists) ) 
	{
		throw "Failed to create team project!" 
	}
}

function New-VstsProject 
{
	<#
		.SYNOPSIS
			Creates a new project in a VSTS account
	#>
	param(
	[Parameter(Mandatory, ParameterSetname='Account')]$AccountName, 
	[Parameter(Mandatory, ParameterSetname='Account')]$User, 
	[Parameter(Mandatory, ParameterSetname='Account')]$Token, 
	[Parameter(Mandatory, ParameterSetname='Session')]$Session, 
	[Parameter(Mandatory)]$Name, 
	[Parameter()]$Description, 
	[Parameter()][ValidateSet('Git')]$SourceControlType = 'Git',
	[Parameter()]$TemplateTypeId = '6b724908-ef14-45cf-84f8-768b5384da45',
	[Parameter()]$TemplateTypeName = 'Agile',
	[Switch]$Wait)

	if ($PSCmdlet.ParameterSetName -eq 'Account')
	{
		$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
	}

	if ($PSBoundParameters.ContainsKey('TemplateTypeName'))
	{
		$TemplateTypeId = Get-VstsProcess -Session $Session | Where Name -EQ $TemplateTypeName | Select -ExpandProperty Id
		if ($TemplateTypeId -eq $null)
		{
			throw "Template $TemplateTypeName not found."
		}
	}

	$Body = @{
		name = $Name
		description = $Description
		capabilities = @{
			versioncontrol = @{
				sourceControlType = $SourceControlType
			}
			processTemplate = @{
				templateTypeId = $TemplateTypeId
			}
		}
	} | ConvertTo-Json

	Invoke-VstsEndpoint -Session $Session -Path 'projects' -Method POST -Body $Body

	if ($Wait)
	{
		Wait-VSTSProject -Session $Session -Name $Name -Exists
	}
}

function Remove-VSTSProject {
	<#
		.SYNOPSIS 
			Deletes a project from the specified VSTS account.
	#>
	param(
		[Parameter(Mandatory, ParameterSetname='Account')]$AccountName, 
		[Parameter(Mandatory, ParameterSetname='Account')]$User, 
		[Parameter(Mandatory, ParameterSetname='Account')]$Token, 
		[Parameter(Mandatory, ParameterSetname='Session')]$Session,  
		[Parameter(Mandatory)]$Name,
		[Parameter()][Switch]$Wait)

		if ($PSCmdlet.ParameterSetName -eq 'Account')
		{
			$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
		}

		$Id = Get-VstsProject -Session $Session -Name $Name | Select -ExpandProperty Id

		if ($Id -eq $null)
		{
			throw "Project $Name not found in $AccountName."
		}

		Invoke-VstsEndpoint -Session $Session -Path "projects/$Id" -Method DELETE

		if ($Wait)
		{
			Wait-VSTSProject -Session $Session -Name $Name
		}
}

function Get-VstsWorkItem {
<#
    .SYNOPSIS 
        Get work items from VSTS
#>
    param(
	[Parameter(Mandatory, ParameterSetname='Account')]$AccountName, 
	[Parameter(Mandatory, ParameterSetname='Account')]$User, 
	[Parameter(Mandatory, ParameterSetname='Account')]$Token, 
	[Parameter(Mandatory, ParameterSetname='Session')]$Session, 
	[Parameter(Mandatory)]$Id)

	if ($PSCmdlet.ParameterSetName -eq 'Account')
	{
		$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
	}

	Invoke-VstsEndpoint -Session $Session -Path 'wit/workitems' -QueryStringParameters @{ids = $id}
}

function New-VstsWorkItem {
<#
    .SYNOPSIS 
        Create new work items in VSTS
#>
    param(
	[Parameter(Mandatory, ParameterSetname='Account')]
	$AccountName, 
	[Parameter(Mandatory, ParameterSetname='Account')]
	$User, 
	[Parameter(Mandatory, ParameterSetname='Account')]
	$Token, 
	[Parameter(Mandatory, ParameterSetname='Session')]
	$Session, 
	[Parameter(Mandatory)]
	$Project,
	[Parameter()]
	[Hashtable]
	$PropertyHashtable, 
	[Parameter(Mandatory)]
	[string]
	$WorkItemType
	)

    if ($PSCmdlet.ParameterSetName -eq 'Account')
	{
		$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
	}

	if ($PropertyHashtable -ne $null)
	{
	    $Fields = foreach($kvp in $PropertyHashtable.GetEnumerator())
		{
			[PSCustomObject]@{
				op = 'add'
				path = '/fields/' + $kvp.Key
				value = $kvp.value
			}
		}

		$Body = $Fields | ConvertTo-Json
	}
	else
	{
		$Body = [String]::Empty
	}

	Invoke-VstsEndpoint -Session $Session -Path "wit/workitems/`$$($WorkItemType)" -Method PATCH -Project $Project -Body $Body
}

function Get-VstsWorkItemQuery {
    <#
    .SYNOPSIS 
        Returns a list of work item queries from the specified folder.
    #>
    param(
	[Parameter(Mandatory, ParameterSetname='Account')]
	$AccountName, 
	[Parameter(Mandatory, ParameterSetname='Account')]
	$User, 
	[Parameter(Mandatory, ParameterSetname='Account')]
	$Token, 
	[Parameter(Mandatory, ParameterSetname='Session')]
	$Session, 
    [Parameter(Mandatory=$true)]$Project, 
    $FolderPath)

	if ($PSCmdlet.ParameterSetName -eq 'Account')
	{
		$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
	}

    $Result = Invoke-VstsEndpoint -Session $Session -Project $Project -Path 'wit/queries' -QueryStringParameters @{depth=1}

    foreach($value in $Result.Value)
    {
        if ($Value.isFolder -and $Value.hasChildren)
        {
            Write-Verbose "$Value.Name"
            foreach($child in $value.Children)
            {
                if (-not $child.isFolder)
                {
                    $child
                }
            }
        }
    } 
}

function New-VstsGitRepository {
    <#
        .SYNOPSIS
            Creates a new Git repository in the specified team project. 
    #>
    param(
	[Parameter(Mandatory, ParameterSetname='Account')]
	$AccountName, 
	[Parameter(Mandatory, ParameterSetname='Account')]
	$User, 
	[Parameter(Mandatory, ParameterSetname='Account')]
	$Token, 
	[Parameter(Mandatory, ParameterSetname='Session')]
	$Session, 
    [Parameter(Mandatory=$true)]
	$Project,
    [Parameter(Mandatory=$true)]
	$RepositoryName)  

	if ($PSCmdlet.ParameterSetName -eq 'Account')
	{
		$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
	}

	if (-not (Test-Guid $Project))
	{
		$Project = Get-VstsProject -Session $Session -Name $Project | Select -ExpandProperty Id
	}

    $Body = @{
        Name = $RepositoryName
        Project = @{
            Id = $Project
        }
    } | ConvertTo-Json

	Invoke-VstsEndpoint -Session $Session -Method POST -Path 'git/repositories' -Body $Body
}

function Get-VstsGitRepository {
    <#
        .SYNOPSIS
            Gets Git repositories in the specified team project. 
    #>
        param(
		[Parameter(Mandatory, ParameterSetname='Account')]
		$AccountName, 
		[Parameter(Mandatory, ParameterSetname='Account')]
		$User, 
		[Parameter(Mandatory, ParameterSetname='Account')]
		$Token, 
		[Parameter(Mandatory, ParameterSetname='Session')]
		$Session, 
        [Parameter(Mandatory=$true)]$Project)

	if ($PSCmdlet.ParameterSetName -eq 'Account')
	{
		$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
	}

     $Result = Invoke-VstsEndpoint -Session $Session -Project $Project -Path 'git/repositories' -QueryStringParameters @{depth=1}
     $Result.Value              
}

function Get-VstsCodePolicy {
    <#
        .SYNOPSIS
            Get code policies for the specified project. 
    #>

    param(
	    [Parameter(Mandatory, ParameterSetname='Account')]
		$AccountName, 
		[Parameter(Mandatory, ParameterSetname='Account')]
		$User, 
		[Parameter(Mandatory, ParameterSetname='Account')]
		$Token, 
		[Parameter(Mandatory, ParameterSetname='Session')]
		$Session, 
        [Parameter(Mandatory=$true)]$Project)

		
	if ($PSCmdlet.ParameterSetName -eq 'Account')
	{
		$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
	}
			  
     $Result = Invoke-VstsEndpoint -Session $Session -Project $Project -Path 'policy/configurations' -ApiVersion '2.0-preview.1'
     $Result.Value     
}

function New-VstsCodePolicy {
    <#
        .SYNOPSIS
            Creates a new Code Policy configuration for the specified project.
    #>

    param(
		[Parameter(Mandatory, ParameterSetname='Account')]
		$AccountName, 
		[Parameter(Mandatory, ParameterSetname='Account')]
		$User, 
		[Parameter(Mandatory, ParameterSetname='Account')]
		$Token, 
		[Parameter(Mandatory, ParameterSetname='Session')]
		$Session, 
        [Parameter(Mandatory=$true)]
		$Project,
        [Guid]
		$RepositoryId = [Guid]::Empty,
        [int]
		$MinimumReviewers,
        [string[]]
		$Branches)

    $RepoId = $null
    if ($RepositoryId -ne [Guid]::Empty)
    {
        $RepoId = $RepositoryId.ToString()   
    }

    $scopes = foreach($branch in $Branches)
    {
        @{
            repositoryId = $RepoId
            refName = "refs/heads/$branch"
            matchKind = "exact"
        }
    }

    $Policy = @{
        isEnabled = $true
        isBlocking = $false
        type = @{
            id = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'
        }
        settings = @{
            minimumApproverCount = $MinimumReviewers
            creatorVoteCounts = $false
            scope = @($scopes)
        }
    } | ConvertTo-Json -Depth 10

    if ($PSCmdlet.ParameterSetName -eq 'Account')
	{
		$Session = New-VSTSSession -AccountName $AccountName -User $User -Token $Token
	}

	Invoke-VstsEndpoint -Session $Session -Project $Project -ApiVersion '2.0-preview.1' -Body $Policy -Method POST
}

function Get-VstsProcess {
    <#
        .SYNOPSIS
            Gets team project processes.
    #>

    param(
		[Parameter(Mandatory)]
		$Session)

     $Result = Invoke-VstsEndpoint -Session $Session -Path 'process/processes'
     $Result.Value     
}

function Get-VstsBuild {
    <#
        .SYNOPSIS
            Gets team project builds.
    #>

    param(
		[Parameter(Mandatory)]
		$Session,
		[Parameter(Mandatory)]
		$Project)

     $Result = Invoke-VstsEndpoint -Session $Session -Path 'build/builds' -Project $Project -ApiVersion '2.0'
     $Result.Value     
}

function Get-VstsBuildDefinition {
    <#
        .SYNOPSIS
            Gets team project build definitions.
    #>

    param(
		[Parameter(Mandatory)]
		$Session,
		[Parameter(Mandatory)]
		$Project)

     $Result = Invoke-VstsEndpoint -Session $Session -Path 'build/definitions' -Project $Project -ApiVersion '2.0'
     $Result.Value     
}

function Test-Guid {
	param([Parameter(Mandatory)]$Input)

	$Guid = [Guid]::Empty
	[Guid]::TryParse($Input, [ref]$Guid)
}

function New-VstsBuildDefinition {
	<#
        .SYNOPSIS
            Gets build definitions for the specified project.
    #>

	param(
		[Parameter(Mandatory)]
		$Session,
	    [Parameter(Mandatory=$true)]
		$Project,
		[Parameter(Mandatory=$true)]
		$Name,
		[Parameter()]
		$DisplayName = $Name,
		[Parameter()]
		$Comment,
		[Parameter(Mandatory=$true)]
		$Queue,
		[Parameter(Mandatory=$true)]
		[PSCustomObject]$Repository 
	)

	if (-not (Test-Guid -Input $Queue))
	{
		$Queue = Get-VstsBuildQueue -Session $Session | Where Name -EQ $Queue | Select -ExpandProperty Id
	}

	$Body = @{
	  name =  $Name
	  type = "build"
	  quality = "definition"
	  queue = @{
		id = $Queue
	  }
	  build = @(
		@{
		  enabled = $true
		  continueOnError = $false
		  alwaysRun = $false
		  displayName = $DisplayName
		  task = @{
			id = "71a9a2d3-a98a-4caa-96ab-affca411ecda"
			versionSpec = "*"
		  }
		  inputs = @{
			"solution" = "**\\*.sln"
			"msbuildArgs" = ""
			"platform" = '$(platform)'
			"configuration"= '$(config)'
			"clean" = "false"
			"restoreNugetPackages" = "true"
			"vsLocationMethod" = "version"
			"vsVersion" = "latest"
			"vsLocation" =  ""
			"msbuildLocationMethod" = "version"
			"msbuildVersion" = "latest" 
			"msbuildArchitecture" = "x86"
			"msbuildLocation" = ""
			"logProjectEvents" = "true"
		  }
		},
		@{
		  "enabled" = $true
		  "continueOnError" = $false
		  "alwaysRun" = $false
		  "displayName" = "Test Assemblies **\\*test*.dll;-:**\\obj\\**"
		  "task" = @{
			"id" = "ef087383-ee5e-42c7-9a53-ab56c98420f9"
			"versionSpec" = "*"
		  }
		  "inputs" = @{
			"testAssembly" = "**\\*test*.dll;-:**\\obj\\**"
			"testFiltercriteria" = ""
			"runSettingsFile" = ""
			"codeCoverageEnabled" = "true"
			"otherConsoleOptions" = ""
			"vsTestVersion" = "14.0"
			"pathtoCustomTestAdapters" = ""
		  }
		}
	  )
	  "repository" = @{
		"id" = $Repository.Id
		"type" = "tfsgit"
		"name" = $Repository.Name
		"localPath" = "`$(sys.sourceFolder)/$($Repository.Name)"
		"defaultBranch" ="refs/heads/master"
		"url" = $Repository.Url
		"clean" = "false"
	  }
	  "options" = @(
		@{
		  "enabled" = $true
		  "definition" = @{
			"id" = "7c555368-ca64-4199-add6-9ebaf0b0137d"
		  }
		  "inputs" = @{
			"parallel" = "false"
			"multipliers" = @("config","platform")
		  }
		}
	  )
	  "variables" = @{
		"forceClean" = @{
		  "value" = "false"
		  "allowOverride" = $true
		}
		"config" =  @{
		  "value" = "debug, release"
		  "allowOverride" = $true
		}
		"platform" = @{
		  "value" = "any cpu"
		  "allowOverride" = $true
		}
	  }
	  "triggers" = @()
	  "comment" = $Comment
	} | ConvertTo-Json -Depth 20

	Invoke-VstsEndpoint -Session $Session -Path 'build/definitions' -ApiVersion 2.0 -Method POST -Body $Body -Project $Project
}

function Get-VstsBuildQueue {
	<#
        .SYNOPSIS
            Gets build definitions for the collection.
    #>

	param(
		[Parameter(Mandatory)]
		$Session
		)

	 $Result = Invoke-VstsEndpoint -Session $Session -Path 'build/queues' -ApiVersion 2.0
     $Result.Value   
}

function ConvertTo-VstsGitRepository {
	<#
		.SYNOPSIS
			Converts a TFVC repository to a VSTS Git repository. 
	#>
    param(
		[Parameter(Mandatory)]$Session,
		[Parameter(Mandatory)]$TargetName, 
		[Parameter(Mandatory)]$SourceFolder, 
		[Parameter(Mandatory)]$ProjectName)

	$GitCommand = Get-Command git 
	if ($GitCommand -eq $null -or $GitCommand.CommandType -ne 'Application' -or $GitCommand.Name -ne 'git.exe')
	{
		throw "Git-tfs needs to be installed to use this command. See https://github.com/git-tfs/git-tfs. You can install with Chocolatey: cinst gittfs"
	}

	$GitTfsCommand = Get-Command git-tfs 
	if ($GitTfsCommand -eq $null -or $GitTfsCommand.CommandType -ne 'Application' -or $GitTfsCommand.Name -ne 'git-tfs.exe')
	{
		throw "Git-tfs needs to be installed to use this command. See https://github.com/git-tfs/git-tfs. You can install with Chocolatey: cinst gittfs"
	}

    git tfs clone "https://$($Session.AccountName).visualstudio.com/defaultcollection" "$/$ProjectName/$SourceFolder" --branches=none

    Push-Location (Split-Path $SourceFolder -Leaf)

    New-VstsGitRepository -Session $Session -RepositoryName $TargetName -Project $ProjectName | Out-Null

    git checkout -b develop
    git remote add origin https://$($Session.AccountName).visualstudio.com/DefaultCollection/$ProjectName/_git/$TargetName
    git push --all origin
    git tfs cleanup

    Pop-Location
	Remove-Item (Split-Path $SourceFolder -Leaf) -Force
}