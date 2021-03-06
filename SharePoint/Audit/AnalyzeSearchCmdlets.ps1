############################################################################################################################################
# Script para el análisis de las estadísticas del buscador
# Parametros necesarios: N/A
############################################################################################################################################

Add-Type @'
using System;
using System.Linq;
public class LinkStoreResult
{
    public int Position { get; set; }
    public double Score { get; set; }
    public string Uri { get; set; }
    public bool IsPromoted { get; set; }
    public bool IsResultBlock { get; set; }
    public bool IsNatural { get; set; }
    public bool IsClicked { get; set; }
    public string ClickType { get; set; }
    public string ResultEncoded
    {
        get { return string.Join("##", new string[] { Position.ToString(), Score.ToString(), Uri, IsPromoted.ToString(), IsResultBlock.ToString(), IsNatural.ToString(), IsClicked.ToString(), ClickType }); }
        set
        {
            if (string.IsNullOrEmpty(value)) return;
            var splits = value.Split(new [] { "##" }, System.StringSplitOptions.None);
            Position = int.Parse(splits[0]);
            Score = double.Parse(splits[1]);
            Uri = splits[2];
            IsPromoted = bool.Parse(splits[3]);
            IsResultBlock = bool.Parse(splits[4]);
            IsNatural = bool.Parse(splits[5]);
            IsClicked = bool.Parse(splits[6]);
            ClickType = splits[7];
        }
    }
}
public class LinkStoreEntry
{
    public System.DateTime Day { get; set; }
    public System.DateTime Timestamp { get; set; }
    public int QueryId { get; set; }
    public int QueryBaseId { get; set; }
    public int QueryHash { get; set; }
    public string Query { get; set; }
    public string Site { get; set; }
    public string Web { get; set; }
    public string Source { get; set; }
    public string SessionId { get; set; }
    public string[] Refiners { get; set; }
    public string[] AppliedQueryRules { get; set; }
    public LinkStoreResult[] Results { get; set; }
    public string RefinersEncoded
    {
        get { return (Refiners == null) ? "" : string.Join("|", Refiners); }
        set { Refiners = (string.IsNullOrEmpty(value)) ? null : value.Split('|'); }
    }
    public string AppliedQueryRulesEncoded
    {
        get { return (AppliedQueryRules == null) ? "" : string.Join("|", AppliedQueryRules); }
        set { AppliedQueryRules = (string.IsNullOrEmpty(value)) ? null : value.Split('|'); }
    }
    public string ResultsEncoded
    {
        get { return (Results == null) ? "" : string.Join("||", Results.Select(x => x.ResultEncoded)); }
        set { Results = (string.IsNullOrEmpty(value)) ? null : value.Split(new [] { "||" }, System.StringSplitOptions.RemoveEmptyEntries).Select(x => new LinkStoreResult { ResultEncoded = x }).ToArray(); }
    }

    public LinkStoreEntry()
    {
        Refiners = new string[0];
        AppliedQueryRules = new string[0];
        Results = new LinkStoreResult[0];
    }
}
'@

# =====================
# Utility Functions
# =====================
function Get-GzipContent($path)
{
    trap
    {
        Write-Error "failed reading file $path"
        if ($inhandle -ne $null) { $inhandle.Close() }
        if ($gziphandle -ne $null) { $gziphandle.Close() }
        if ($reader -ne $null) { $reader.Close() }
    }

    $inhandle   = [IO.File]::OpenRead($path)
    $gziphandle = New-Object System.IO.Compression.GZipStream $inhandle, ([IO.Compression.CompressionMode]::Decompress)
    $reader     = New-Object System.IO.StreamReader $gziphandle
        
    while ($reader.EndOfStream -ne $true)
    {
        Write-Output $reader.ReadLine()
    }

    $inhandle.Close()
    $gziphandle.Close()
    $reader.Close()
}

function Gzip-File
{
	param
	(
		[string] $InFile = $(throw "InFile is required."),
		[string] $OutFile = $($InFile + ".gz"),
		[switch] $Delete
	)

	trap
	{
		if ($inhandle) { $inhandle.Close() }
		if ($gziphandle) { $gziphandle.Close() }
		if ($outhandle) { $outhandle.Close() }
		
		Write-Error "unhandled exception zipping file $InFile"
		return
	}

	# root paths
	if (!([IO.Path]::IsPathRooted($InFile)))
	{
		$InFile  = [IO.Path]::Combine([IO.Directory]::GetCurrentDirectory(), $InFile)
	}
	if (!([IO.Path]::IsPathRooted($OutFile)))
	{
		$OutFile  = [IO.Path]::Combine([IO.Directory]::GetCurrentDirectory(), $OutFile)
	}

	if (!(Test-Path -path $InFile))
	{
		Write-Error "input file $InFile doesn't exist"
		return
	}

	$inhandle   = [IO.File]::OpenRead($InFile)
	$outhandle  = [IO.File]::Create($OutFile)
	$gziphandle = New-Object System.IO.Compression.GZipStream $outhandle, ([IO.Compression.CompressionMode]::Compress)

	$buffer = New-Object byte[](4096)
	$bytesread = 0

	while (($bytesread = $inhandle.Read($buffer, 0, $buffer.Length)) -gt 0)
	{
		$gziphandle.Write($buffer, 0, $bytesread)
	}

	$gziphandle.Flush()
	$gziphandle.Close()
	$outhandle.Close()
	$inhandle.Close()

	if ($Delete)
	{
		Remove-Item $InFile
	}
}

function Export-SPLinkStoreEntries
{
    param
    (
        [string] $BaseDirectory = "."
    )

    if ((Test-Path $BaseDirectory) -ne $true)
    {
        Write-Error "Invalid directory: $BaseDirectory"
        return
    }

    # group and write
    foreach ($group in ($input | Group-Object { $_.Day.ToString("yyyy-MM-dd") }))
    {
        $path = Join-Path $BaseDirectory ("{0}.csv" -f $group.Name)
        $group.Group | Sort-Object Timestamp | Select-Object Day,Timestamp,QueryId,QueryBaseId,QueryHash,Query,Site,Web,Source,SessionId,RefinersEncoded,AppliedQueryRulesEncoded,ResultsEncoded | Export-Csv -Path $path -NoTypeInformation
        Gzip-File -InFile $path -Delete
    }
}
# =====================
# Plugin Functions
# =====================
function Get-SPUsagePerformanceEntries
{
    param
    (
        [TimeSpan] $Span = [TimeSpan]::FromDays(7),
        [DateTime] $Start = ([DateTime]::Now - $Span)
    )

    # primary extraction query
    $Query = @"
SELECT 
    CONCAT(DATEPART("yyyy", [LogTime]), RIGHT('0' + CONVERT(varchar(2), DATEPART("mm", [LogTime])), 2), RIGHT('0' + CONVERT(varchar(2), DATEPART("dd", [LogTime])), 2), RIGHT('0' + CONVERT(varchar(2), DATEPART("hh", [LogTime])), 2)) AS LogHour
    ,[MachineName]
    ,[ApplicationType]
    ,SUM([NumQueries]) AS QueryCount
	,SUM([TotalQueryTimeMs]) AS QueryTime
	,SUM([FirstPassMs]) AS FirstPassTime
	,SUM([SecondPassMs]) AS SecondPassTime
	,SUM([TangoTimeMs]) AS TangoTime
	,SUM([MergeTimeMs]) AS MergeTime
	,SUM([QueryLookupMs]) AS LookupTime
	,SUM([DocSumLookupMs]) AS DocsumTime
FROM 
    [Search_PerMinuteIndexLookupQueryLatency]
WHERE 
    [ApplicationType] IS NOT NULL AND [LogTime] >= '{0}' AND [LogTime] < '{1}'
GROUP BY 
    [MachineName], 
    [ApplicationType], 
    CONCAT(DATEPART("yyyy", [LogTime]), RIGHT('0' + CONVERT(varchar(2), DATEPART("mm", [LogTime])), 2), RIGHT('0' + CONVERT(varchar(2), DATEPART("dd", [LogTime])), 2), RIGHT('0' + CONVERT(varchar(2), DATEPART("hh", [LogTime])), 2))
"@

    # check for existence of SharePoint cmdlets 
    if ((Get-PSSnapin -Name Microsoft.SharePoint.PowerShell -Registered -ErrorAction SilentlyContinue) -eq $null)
    {
        Write-Error "No PowerShell snapins could be located. Does this machine have them installed?"
        return
    }
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue

    # locate usage application
    $ua = Get-SPUsageApplication
    if ($ua.LoggingEnabled -ne $true)
    {
        Write-Error "Usage Application is not configured for logging."
        return
    }

    # run query
    $q = ($Query -f $Start, ($Start + $Span))
    $dataSet = New-Object System.Data.DataSet "SPUsagePerformanceEntries"
    if ((New-Object System.Data.SqlClient.SqlDataAdapter($q, $ua.UsageDatabase.DatabaseConnectionString)).Fill($dataSet)) 
    {
        $dataSet.Tables[0] | Write-Output
    }
}

function Get-SPLinkStoreEntries
{						
    param
    (
        [string] $FromLocation,
        [string] $FromSsa,
        [DateTime] $Start = [DateTime]::Now,
        [TimeSpan] $Span = [TimeSpan]::FromDays(1)
    )   

    # internal mapping function for click types
    function Get-ClickType($type)
    {
        if ([String]::IsNullOrEmpty($type) -eq $true) { return $type }

        switch ($type)
        {
            "0" { "Result" }
            "1" { "InsideBlock" }
            "2" { "MoreInsideBlock" }
            "3" { "DeepLink" }
            "4" { "HoverNoPreview" }
            "5" { "HoverWithPreview" }
            "6" { "HoverInSection" }
            "7" { "ActionFollow" }
            "8" { "ActionViewLibrary" }
            "9" { "ActionEdit" }
            "10" { "ActionSend" }
            "11" { "ActionViewDuplicates" }
            default { "CustomAction" }
        }
    }

    # internal function to attempt to directly load from SharePoint
    function Read-FromSharePoint
    {
        # primary extraction query
        $Query = @"
SELECT 
	Q.pageImpressionId AS pageImpressionId, 
	Q.queryString AS queryString, 
    Q.queryHash AS queryHash,
	Q.basePageImpressionId AS basePageImpressionId, 
	Q.searchTime AS searchTime, 
	Q.siteGuid AS siteId, 
	Q.webGuid AS webId,
	Q.originalSourceId AS sourceId, 
	Q.advancedSearch AS advancedSearch, 
	Q.didYouMean AS didYouMean, 
	Q.continued AS continued, 
	Q.sessionId AS sessionId, 
	Q.refiners AS refiners, 
	Q.suggestedQuery AS suggestedQuery, 
	RI.blockType AS blockType, 
	RI.resultPosition AS position, 
	RI.score AS score,
	RD.url AS url,  
	C.clickType AS clickType, 
	C.clickTime AS clickTime,
	(SELECT CONVERT(nvarchar(128), queryRuleId) + ','  as [text()] FROM {0}.dbo.MSSQLogPageImpressionQueryRule WHERE pageImpressionId = Q.pageImpressionId FOR XML PATH('')) as queryRules
FROM
	{0}.dbo.MSSQLogPageImpressionQuery AS Q WITH(nolock)
	LEFT OUTER JOIN {0}.dbo.MSSQLogPageImpressionResult AS RI WITH(nolock) ON Q.pageImpressionId = RI.pageImpressionId
	LEFT JOIN {0}.dbo.MSSQLogResultDocs AS RD WITH(nolock) ON RI.resultDocID = RD.resultDocId
	LEFT OUTER JOIN {0}.dbo.MSSQLogPageClick AS C WITH(nolock) ON RI.pageImpressionId = C.pageImpressionId AND RI.resultPosition = C.resultPosition
WHERE
	Q.searchTime >= '{1}' AND Q.searchTime < '{2}'
ORDER BY
	Q.searchTime ASC, Q.pageImpressionId ASC
"@

        # check for existence of SharePoint cmdlets 
        if ((Get-PSSnapin -Name Microsoft.SharePoint.PowerShell -Registered -ErrorAction SilentlyContinue) -eq $null)
        {
            Write-Error "No PowerShell snapins could be located. Does this machine have them installed?"
            return
        }
        Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue

        # locate ssa
        $ssa = Get-SPEnterpriseSearchServiceApplication $FromSsa

        # common mappings
        $sources = @{}
        $rules = @{}
        $sites = @{}

        $fedman = New-Object Microsoft.Office.Server.Search.Administration.Query.FederationManager($ssa)
        $owner = Get-SPEnterpriseSearchOwner -Level Ssa

        foreach ($source in $fedman.ListSources($owner, $true))
        {
	        $sources[$source.Id.ToString()] = $source.Name
        }

        $ruleman = new-object Microsoft.Office.Server.Search.Query.Rules.QueryRuleManager($ssa)        
        foreach ($rule in $ruleman.GetQueryRules($owner))
        {
	        $rules[$rule.Id.ToString()] = $rule.Name
        }

        foreach ($site in Get-SPSite -Limit ALL)
        {
            $sites[$site.Id.ToString()] = $site.Url
        }

        # internal function to parse a sql record
        function Parse-Record($record)
        {
            #trap { return $null }

            # results parsing
            $results = @()
            if ([String]::IsNullOrEmpty($record.url) -ne $true)
            {
                $robj = New-Object LinkStoreResult
                $robj.Position = $record.position
                $robj.Score = $record.score
                $robj.Uri = $record.url
                $robj.IsPromoted = ($record.blockType -eq 0)
                $robj.IsResultBlock = ($record.blockType -eq 100)
                $robj.IsNatural = ($record.blockType -eq 2)
                $robj.IsClicked = ([String]::IsNullOrEmpty($record.clickTime) -ne $true)
                $robj.ClickType = (Get-ClickType $record.clickType)
                $results += $robj
            }

            # formatted and mapped data
            $site = $record.siteId.ToString()
            if ($sites.ContainsKey($site)) { $site = $sites[$site] }

            $source = $record.sourceId.ToString()
            if ($sources.ContainsKey($source)) { $source = $sources[$source] }

            $refiners = @()
            if ($record.refiners.Split) { $refiners = $record.refiners.Split(';') }

            $mappedrules = @()
            if ($record.queryRules.Split) 
            {               
                foreach ($rule in $record.queryRules.Split(';'))
                {
                    if ($rules.ContainsKey($rule)) { $mappedrules += $rules[$rule] }
                    else { $mappedrules += $rule }
                }
            }

            # object construction
            $obj = New-Object LinkStoreEntry
            $obj.Day = ([DateTime]::Parse($record.searchTime.ToString("yyyy-MM-dd")))
            $obj.Timestamp = $record.searchTime
            $obj.QueryId = $record.pageImpressionId
            $obj.QueryBaseId = $record.basePageImpressionId
            $obj.QueryHash = $record.queryHash
            $obj.Query = $record.queryString
            $obj.Site = $site
            $obj.Web = $record.webId
            $obj.Source = $source
            $obj.SessionId = $record.sessionId
            $obj.Refiners = $refiners
            $obj.AppliedQueryRules = $mappedrules
            $obj.Results = $results
            $obj | Write-Output
        }

        # state
        $entry = $null

        # execute query in each link store
        foreach ($store in $ssa.LinksStores)
        {
            $q = ($Query -f $store.Name, $Start, ($Start + $Span))
            $dataSet = New-Object System.Data.DataSet "SPLinkStoreEntries"
            if ((New-Object System.Data.SqlClient.SqlDataAdapter($q, $store.DatabaseConnectionString)).Fill($dataSet)) 
            {
                foreach ($record in $dataSet.Tables[0])
                {
                    $current = Parse-Record $record

                    # state cases
                    if ($current -eq $null) { continue; }
                    if ($entry -eq $null) { $entry = $current; continue }
                    if ($entry.QueryId -eq $current.QueryId) 
                    { 
                        if ($current.Results.Length -gt 0) { $entry.Results += , $current.Results[0] }
                        continue 
                    }

                    # output
                    $entry | Write-Output
                    $entry = $current
                }
            
                # remainder
                if ($entry -ne $null)
                {
                    $entry | Write-Output
                    $entry = $null
                }
            }    
        } 
    }

    # internal function to load previously cached export files
    function Read-FromDisk
    {
        # internal map function
        function Map-Entry($entry)
        {
            foreach ($entry in $input)
            {
                $obj = New-Object LinkStoreEntry
                $obj.Day = $entry.Day
                $obj.Timestamp = $entry.Timestamp
                $obj.QueryId = $entry.QueryId
                $obj.QueryBaseId = $entry.QueryBaseId
                $obj.QueryHash = $entry.QueryHash
                $obj.Query = $entry.Query
                $obj.Site = $entry.Site
                $obj.Web = $entry.Web
                $obj.Source = $entry.Source
                $obj.SessionId = $entry.SessionId
                $obj.RefinersEncoded = $entry.RefinersEncoded
                $obj.AppliedQueryRulesEncoded = $entry.AppliedQueryRulesEncoded
                $obj.ResultsEncoded = $entry.ResultsEncoded
                $obj | Write-Output
            }
        }

        # file date caps
        $fs = $Start.ToString("yyyy-MM-dd")
        $fe = ($Start + $Span).ToString("yyyy-MM-dd")

        foreach ($file in (Get-ChildItem -Path $FromLocation | ?{ $_.Name.Substring(0, 10) -ge $fs -and $_.Name.Substring(0, 10) -lt $fe } ))
        {
            # unzip to temporary file
            $tmpfile = Join-Path $FromLocation ("{0}.tmp.csv" -f $file)
            Get-GzipContent (Join-Path $FromLocation $file) | Set-Content -Path $tmpfile
            
            # import from csv and map
            Import-Csv -Path $tmpfile | Map-Entry

            # scrap tmp file
            Remove-Item -Path $tmpfile
        }
    }

    # primary function execution
    if ($FromLocation)
    {
        Read-FromDisk | Write-Output 
    }
    elseif ($FromSsa)
    {
        Read-FromSharePoint | Write-Output
    }
}

# =====================
# Report Functions
# =====================
Add-Type @'
public class VolumeMetricsEntry
{
    public string Site { get; set; }
    public System.DateTime Day { get; set; }
    public string GroupKey { get; set; }
    public string GroupValue { get; set; }
    public long SessionCount { get; set; }
    public long QueryCount { get; set; }
    public long ClickCount { get; set; }
    public long PromotedClickCount { get; set; }
    public long BlockClickCount { get; set; }
    public long NoResultsCount { get; set; }
    public long RefinedCount { get; set; }
}
'@
function Get-VolumeMetrics
{
    param
    (
        [string] $GroupBy
    )
	
    $groupings = @( "Site", "Day")
    if ($GroupBy) { $groupings += $GroupBy }

    $groups = $input | Group-Object $groupings

    foreach ($group in $groups)
    {
        $entry = New-Object VolumeMetricsEntry
        $entry.Site = $group.Group[0].Site
        $entry.Day = $group.Group[0].Day
        if ($GroupBy)
        {
            $entry.GroupKey = $GroupBy
            $entry.GroupValue = $group.Group[0].$GroupBy
        }

		$results = $group.Group | ?{ $_.Results -ne $null } | Select-Object -ExpandProperty Results
		
        # metrics
        $entry.SessionCount = ($group.Group | Sort-Object SessionId -Unique | Measure-Object).Count
        $entry.QueryCount = $group.Group.Count
        $entry.ClickCount = ($results | ?{ $_.IsNatural } | Measure-Object).Count
        $entry.PromotedClickCount = ($results | ?{ $_.IsPromoted } | Measure-Object).Count
        $entry.BlockClickCount = ($results | ?{ $_.IsResultBlock } | Measure-Object).Count
        $entry.NoResultsCount = ($group.Group | ?{ $_.Results -eq $null -or $_.Results.Count -eq 0 } | Measure-Object).Count
        $entry.RefinedCount = ($group.Group | ?{ $_.Refiners -ne $null -and $_.Refiners.Count -gt 0 } | Measure-Object).Count
        $entry | Write-Output
    }
}

Add-Type @'
public class QueryMetricsEntry
{
    public string Site { get; set; }
    public string Query { get; set; }
    public System.DateTime Day { get; set; }
    public string GroupKey { get; set; }
    public string GroupValue { get; set; }
    public long QueryCount { get; set; }
    public double VolumeInSite { get; set; }
    public long ClickCount { get; set; }
    public long ClicksFirstPage { get; set; }
    public long ClicksSecondPage { get; set; }
    public long PromotedClickCount { get; set; }
    public long BlockClickCount { get; set; }
    public long NoResultsCount { get; set; }
}
'@
function Get-QueryMetrics
{
    param
    (
        [int] $FirstPageLimit = 10,
        [int] $SecondPageLimit = 20,
        [int] $Limit = 25,
        [string] $GroupBy
    )

    $groupings = @( "Site", "Day" )
    if ($GroupBy) { $groupings += $GroupBy }

    $groups = $input | Group-Object $groupings

    foreach ($group in $groups)
    {
        # track all traffic for site/day/group
        $alltraffic = [double] $group.Group.Count

        # group internal on query
        $querygroups = $group.Group | Group-Object QueryHash | Sort-Object Count -Descending | Select-Object -First $Limit
        foreach ($querygroup in $querygroups)
        {
            $entry = New-Object QueryMetricsEntry
            $entry.Site = $querygroup.Group[0].Site
            $entry.Day = $querygroup.Group[0].Day
            $entry.Query = $querygroup.Group[0].Query
            if ($GroupBy)
            {
                $entry.GroupKey = $GroupBy
                $entry.GroupValue = $querygroup.Group[0].$GroupBy
            }

            $results = $querygroup.Group | ?{ $_.Results -ne $null } | Select-Object -ExpandProperty Results

			# metrics
            $entry.QueryCount = $querygroup.Count
            $entry.VolumeInSite = ([double] $querygroup.Count / $alltraffic)
            $entry.ClickCount = ($results | ?{ $_.IsNatural } | Measure-Object).Count
            $entry.ClicksFirstPage = ($results | ?{ $_.IsNatural -and $_.Position -le $FirstPageLimit } | Measure-Object).Count
            $entry.ClicksSecondPage = ($results | ?{ $_.IsNatural -and $_.Position -gt $FirstPageLimit -and $_.Position -le $SecondPageLimit } | Measure-Object).Count
            $entry.PromotedClickCount = ($results | ?{ $_.IsPromoted } | Measure-Object).Count
            $entry.BlockClickCount = ($results | ?{ $_.IsResultBlock } | Measure-Object).Count
            $entry.NoResultsCount = ($querygroup.Group | ?{ $_.Results -eq $null -or $_.Results.Count -eq 0 } | Measure-Object).Count
            $entry | Write-Output
        }   
    }
}

Add-Type @'
public class UriMetricsEntry
{
    public string Site { get; set; }
    public string Query { get; set; }
    public string Uri { get; set; }
    public System.DateTime Day { get; set; }
    public string GroupKey { get; set; }
    public string GroupValue { get; set; }
    public long ImpressionCount { get; set; }
    public long ClickCount { get; set; }
    public int Position { get; set; }
    public long PromotedClickCount { get; set; }
    public long BlockClickCount { get; set; }
}
'@
function Get-UriMetrics
{
    param
    (
        [int] $Limit = 25,
        [string] $GroupBy,
        [switch] $SortByPromoted,
        [switch] $SortByBlocks
    )

    $sortby = "IsNatural"
    if ($SortByPromoted)
    {
        $sortby = "IsPromoted"
    }
    elseif ($SortByBlocks)
    {
        $sortby = "IsResultBlock"
    }
    
    $groupings = @( "Site", "Day" )
    if ($GroupBy) { $groupings += $GroupBy }

    $sitegroups = $input | Group-Object $groupings

    foreach ($site in $sitegroups)
    {
        foreach ($query in ($site.Group | Group-Object QueryHash | Sort-Object Count -Descending | Select-Object -First $Limit))
        {
            foreach ($uri in ($query.Group | ?{ $_.Results -ne $null } | Select-Object -ExpandProperty Results | ?{ $_.IsClicked -and $_.$sortby } | Group-Object Uri | Sort-Object Count -Descending | Select-Object -First $Limit))
            {
                $obj = New-Object UriMetricsEntry
                $obj.Site = $query.Group[0].Site
                $obj.Query = $query.Group[0].Query
                $obj.Day = $query.Group[0].Day
                $obj.Uri = $uri.Group[0].Uri
                $obj.Position = $uri.Group[0].Position
                if ($GroupBy)
                {
                    $obj.GroupKey = $GroupBy
                    $obj.GroupValue = $query.Group[0].$GroupBy
                }

                $obj.ImpressionCount = $uri.Group.Count
                $obj.ClickCount = ($uri.Group | ?{ $_.IsNatural }).Count
                $obj.PromotedClickCount = ($uri.Group | ?{ $_.IsPromoted }).Count
                $obj.BlockClickCount = ($uri.Group | ?{ $_.IsResultBlock }).Count
                $obj | Write-Output
            }
        }
    }
}

Add-Type @'
public class RefinerMetricsEntry
{
    public string Site { get; set; }
    public System.DateTime Day { get; set; }
    public string Refiner { get; set; }
    public string RefinedValue { get; set; }    
    public string GroupKey { get; set; }
    public string GroupValue { get; set; }
    public long RefinedCount { get; set; }
}
'@
function Get-RefinerMetrics
{
    param
    (
        [int] $Limit = 25,
        [string] $GroupBy
    )

    $groupings = @( "Site", "Day" )
    if ($GroupBy) { $groupings += $GroupBy }

    $groups = $input | ?{ $_.Refiners -ne $null -and $_.Refiners.Count -gt 0 } | Group-Object $groupings
    foreach ($group in $groups)
    {
        $refiners = $group.Group | Select-Object -ExpandProperty Refiners |  Group-Object { $_.Substring(0, $_.IndexOf(':')) } | Sort-Object Count -Descending | Select-Object -First $Limit
        foreach ($r in $refiners)
        {
            $obj = New-Object RefinerMetricsEntry
            $obj.Site = $group.Group[0].Site
            $obj.Day = $group.Group[0].Day
            if ($GroupBy)
            {
                $obj.GroupKey = $GroupBy
                $obj.GroupValue = $group.Group[0].$GroupBy
            }

            $obj.Refiner = $r.Name
            $obj.RefinedCount = $r.Count
            $obj | Write-Output
        }
    }
}

Add-Type @'
public class AbandonedMetricsEntry
{
    public string Site { get; set; }
    public System.DateTime Day { get; set; }
    public string Query { get; set; }
    public string NextQuery { get; set; }
    public string GroupKey { get; set; }
    public string GroupValue { get; set; }
    public long AbandonedCount { get; set; }
}
'@
function Get-AbandonedMetrics
{
    param
    (
        [int] $Limit = 25,
        [string] $GroupBy
    )

    $groupings = @( "Site", "Day" )
    if ($GroupBy) { $groupings += $GroupBy }

    $sites = $input | Group-Object $groupings
    foreach ($site in $sites)
    {
        # state
        $abandoned = @{}

        # group up sessions
        $sessions = $site.Group | Group-Object SessionId
        foreach ($session in $sessions)
        {
            # session state
            $previous = @()

            foreach ($query in $sessions.Group | Sort-Object Timestamp)
            {
                $clicks = ($query | Select-Object -ExpandProperty Results | ?{ $_.IsClicked }).Count
                
                # no results
                if ($query.Results.Count -eq 0)
                {
                    continue
                }

                # no clicks
                if ($clicks -eq 0)
                {
                    $previous += $query
                }

                # found clicks, track previous as abandoned linked to this entry
                elseif ($previous.Count -gt 0)
                {
                    foreach ($p in $previous | ?{ $_.QueryHash -ne $query.QueryHash })
                    {
                        $key = "{0} {1}" -f $query.QueryHash, $p.QueryHash
                        if ($abandoned.ContainsKey($key) -ne $true)
                        {
                            $obj = New-Object AbandonedMetricsEntry
                            $obj.Site = $p.Site
                            $obj.Day = $p.Day
                            $obj.Query = $p.Query
                            $obj.NextQuery = $query.Query
                            if ($GroupBy)
                            {
                                $obj.GroupKey = $GroupBy
                                $obj.GroupValue = $group.Group[0].$GroupBy
                            }
                            $abandoned[$key] = $obj
                        }
                        $abandoned[$key].AbandonedCount++
                    }
                    $previous = @()
                }
            }

            # process any remaining abandoned with no link
            if ($previous.Count -gt 0)
            {
                foreach ($p in $previous)
                {
                    if ($abandoned.ContainsKey($p.QueryHash) -ne $true)
                    {
                        $obj = New-Object AbandonedMetricsEntry
                        $obj.Site = $p.Site
                        $obj.Day = $p.Day
                        $obj.Query = $p.Query
                        $obj.NextQuery = ""
                        if ($GroupBy)
                        {
                            $obj.GroupKey = $GroupBy
                            $obj.GroupValue = $group.Group[0].$GroupBy
                        }
                        $abandoned[$p.QueryHash] = $obj
                    }
                    $abandoned[$p.QueryHash].AbandonedCount++
                }
            }
        }

        # write buckets
        $abandoned.Values | Sort-Object AbandonedCount -Descending | Select-Object -First $Limit | Write-Output
    }
}

#####################################################################################
# Convenience wrappers
# These cmdlets stitch together a common scenario for extraction of report generation
#####################################################################################
function Get-SPAnalyticsReports
{
	param
	(
		[string] $SearchServiceApplication = $(throw "SearchServiceApplication is required."),
		[string] $OutputDirectory = (Split-Path -Parent $PSCommandPath),
		[DateTime] $StartDay = [DateTime]::Now,
		[switch] $WholeMonth,
		[switch] $ExtractOnly
	)
	
	if ((Test-Path $OutputDirectory) -ne $true)
	{
		Write-Error "$OutputDirectory does not exist."
		return
	}
	
	# set of days to extract
	$range = @( $StartDay )
	if ($WholeMonth)
	{
		$current = New-Object DateTime $StartDay.Year, $StartDay.Month, 1
		while ($current.Month -eq $StartDay.Month)
		{
			$range += $current
			$current += [TimeSpan]::FromDays(1)
		}
	}
	
	# cleanse dates
	$range = $range | %{ New-Object DateTime $_.Year, $_.Month, $_.Day }
	
	# report filename format
	$filename = "r-{0}-{1:yyyy-MM-dd}.csv"
	if ($WholeMonth)
	{
		$filename = "r-{0}-{1:yyyy-MM}.csv"
	}
	
	# get entries
	foreach ($d in $range)
	{
		$entries = Get-SPLinkStoreEntries -FromSsa $SearchServiceApplication -Start $d -Span "1.00:00:00"
		
		# just dump entries
		if ($ExtractOnly)
		{
			$entries | Export-SPLinkStoreEntries -BaseDirectory $OutputDirectory
		}
		
		# run reports and dump that data
		else
		{
			$entries | Get-VolumeMetrics | Export-Csv -Append -NoTypeInformation -Path (Join-Path $OutputDirectory ($filename -f "volume", $d))
			$entries | Get-QueryMetrics | Export-Csv -Append -NoTypeInformation -Path (Join-Path $OutputDirectory ($filename -f "query", $d))
			$entries | Get-UriMetrics | Export-Csv -Append -NoTypeInformation -Path (Join-Path $OutputDirectory ($filename -f "uri", $d))
			$entries | Get-RefinerMetrics | Export-Csv -Append -NoTypeInformation -Path (Join-Path $OutputDirectory ($filename -f "refiner", $d))
			$entries | Get-AbandonedMetrics | Export-Csv -Append -NoTypeInformation -Path (Join-Path $OutputDirectory ($filename -f "abandon", $d))
		}
	}
}