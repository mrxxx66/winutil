function Get-WinUtilAvailableLanguages {
    <#
    .SYNOPSIS
    Returns available languages from the manifest
    #>
    [CmdletBinding()]
    param()

    process {
        return $sync.configs.locales.locales | ForEach-Object {
            [PSCustomObject]@{
                Code = $_.code
                Name = $_.name
                Version = $_.version
                Url = $_.url
            }
        }
    }
}

function Get-WinUtilLocale {
    <#
    .SYNOPSIS
    Gets locale data with 3-tier resolution: memory -> cache -> download
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code
    )

    process {
        # Tier 1: Memory cache
        if ($null -ne $sync.locales -and $null -ne $sync.locales[$Code]) {
            Write-Debug "Locale '$Code' found in memory cache"
            return $sync.locales[$Code]
        }

        # Initialize locale cache if needed
        if ($null -eq $sync.locales) {
            $sync.locales = @{}
        }

        # Tier 2: Local cache directory
        $cacheDir = "$env:TEMP\WinUtil_Locales"
        $cacheFile = Join-Path $cacheDir "$Code.json"

        if (Test-Path $cacheFile) {
            Write-Debug "Locale '$Code' found in local cache"
            $locale = Get-Content $cacheFile -Raw | ConvertFrom-Json
            $sync.locales[$Code] = $locale
            return $locale
        }

        # Tier 3: Download from URL
        $manifest = $sync.configs.locales.locales | Where-Object { $_.code -eq $Code }
        if ($null -ne $manifest -and $null -ne $manifest.url) {
            Write-Debug "Downloading locale '$Code' from $($manifest.url)"
            try {
                $response = Invoke-WebRequest -Uri $manifest.url -UseBasicParsing -TimeoutSec 30
                $locale = $response.Content | ConvertFrom-Json

                # Save to local cache
                if (-not (Test-Path $cacheDir)) {
                    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
                }
                Set-Content -Path $cacheFile -Value ($locale | ConvertTo-Json -Depth 10) -Encoding UTF8

                $sync.locales[$Code] = $locale
                return $locale
            }
            catch {
                Write-Warning "Failed to download locale '$Code': $_"
                return $null
            }
        }

        # Fallback: if code is 'en', return embedded defaults
        if ($Code -eq 'en') {
            return @{
                _metadata = @{ name = "English"; version = "1.0.0" }
                ui = @{}
                categories = @{}
                descriptions = @{}
            }
        }

        return $null
    }
}

function Set-WinUtilLanguage {
    <#
    .SYNOPSIS
    Applies a language by overlaying translated values onto configs
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code
    )

    process {
        if ($Code -eq 'en') {
            # Restore original English values
            if ($null -ne $sync.configsOriginal) {
                Write-Debug "Restoring original English configs"
                $sync.configs.applications = $sync.configsOriginal.applications.PSObject.Copy()
                $sync.configs.tweaks = $sync.configsOriginal.tweaks.PSObject.Copy()
                $sync.configs.feature = $sync.configsOriginal.feature.PSObject.Copy()
                $sync.configs.appnavigation = $sync.configsOriginal.appnavigation.PSObject.Copy()
            }
            $sync.currentLocale = 'en'
            return
        }

        # Get locale data (from memory, cache, or download)
        $locale = Get-WinUtilLocale -Code $Code
        if ($null -eq $locale) {
            Write-Warning "Locale '$Code' not available"
            return
        }

        # Save original configs on first call
        if ($null -eq $sync.configsOriginal) {
            Write-Debug "Saving original configs for language switching"
            $sync.configsOriginal = @{
                applications = $sync.configs.applications.PSObject.Copy()
                tweaks = $sync.configs.tweaks.PSObject.Copy()
                feature = $sync.configs.feature.PSObject.Copy()
                appnavigation = $sync.configs.appnavigation.PSObject.Copy()
            }
        }

        # Restore original first (clean state)
        $sync.configs.applications = $sync.configsOriginal.applications.PSObject.Copy()
        $sync.configs.tweaks = $sync.configsOriginal.tweaks.PSObject.Copy()
        $sync.configs.feature = $sync.configsOriginal.feature.PSObject.Copy()
        $sync.configs.appnavigation = $sync.configsOriginal.appnavigation.PSObject.Copy()

        # Apply translations
        if ($null -ne $locale.ui) {
            # UI strings translation would be handled in XAML updates
            $sync.uiTranslations = $locale.ui
        }

        if ($null -ne $locale.categories) {
            foreach ($catKey in $locale.categories.PSObject.Properties.Name) {
                # Update category names in navigation
                $prop = $sync.configs.appnavigation.PSObject.Properties[$catKey]
                if ($null -ne $prop) {
                    $prop.Value = $locale.categories.$catKey
                }
            }
        }

        if ($null -ne $locale.descriptions) {
            foreach ($descKey in $locale.descriptions.PSObject.Properties.Name) {
                # Update tweak descriptions
                $tweakProp = $sync.configs.tweaks.PSObject.Properties | Where-Object { $_.Name -match $descKey -and $_.Name -notmatch '^WPF' }
                foreach ($tp in $tweakProp) {
                    if ($null -ne $tp.Value.description) {
                        $tp.Value.description = $locale.descriptions.$descKey
                    }
                }
            }
        }

        # Apply application translations
        if ($null -ne $locale.applications) {
            foreach ($appKey in $locale.applications.PSObject.Properties.Name) {
                $appTrans = $locale.applications.$appKey
                $appProp = $sync.configs.applications.PSObject.Properties[$appKey]
                if ($null -ne $appProp -and $null -ne $appTrans) {
                    if ($null -ne $appTrans.content) {
                        $appProp.Value.content = $appTrans.content
                    }
                    if ($null -ne $appTrans.description) {
                        $appProp.Value.description = $appTrans.description
                    }
                }
            }
        }

        $sync.currentLocale = $Code
        Write-Debug "Language set to '$Code'"
    }
}

function Set-WinUtilLanguageUI {
    <#
    .SYNOPSIS
    Updates XAML UI elements with translated text
    #>
    [CmdletBinding()]
    param()

    process {
        if ($null -eq $sync.uiTranslations) {
            return
        }

        # Update tab headers if translations exist
        $tabMapping = @{
            "WPFTab1BT" = "installTab"
            "WPFTab2BT" = "tweaksTab"
            "WPFTab3BT" = "configTab"
            "WPFTab4BT" = "updatesTab"
            "WPFTab5BT" = "win11IsoTab"
        }

        foreach ($btnName in $tabMapping.Keys) {
            $transKey = $tabMapping[$btnName]
            if ($sync.uiTranslations.$transKey) {
                $sync[$btnName].Content = $sync.uiTranslations.$transKey
            }
        }

        # Update button labels
        $buttonMapping = @{
            "WPFInstall" = "install"
            "WPFUninstall" = "uninstall"
            "WPFInstallUpgrade" = "upgrade"
            "WPFGetInstalled" = "getInstalled"
            "WPFRefresh" = "refresh"
            "WPFRunTweaks" = "runTweaks"
            "WPFUndoTweaks" = "undoTweaks"
            "WPFWin11ISOBrowseButton" = "browse"
            "WPFWin11ISOMountButton" = "mount"
            "WPFWin11ISOModifyButton" = "modify"
            "WPFWin11ISOChooseISOButton" = "export"
            "WPFWin11ISOWriteUSBButton" = "writeUsb"
            "WPFWin11ISOCleanResetButton" = "cleanReset"
        }

        foreach ($btnName in $buttonMapping.Keys) {
            $transKey = $buttonMapping[$btnName]
            if ($sync[$btnName] -and $sync.uiTranslations.$transKey) {
                $sync[$btnName].Content = $sync.uiTranslations.$transKey
            }
        }
    }
}

function Initialize-WinUtilLanguageMenu {
    <#
    .SYNOPSIS
    Initializes the language selection menu
    #>
    [CmdletBinding()]
    param()

    process {
        # Create locale cache directory on startup
        $cacheDir = "$env:TEMP\WinUtil_Locales"
        if (-not (Test-Path $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }

        # Load available languages from manifest
        $languages = Get-WinUtilAvailableLanguages

        # Detect system language and set default
        $systemLocale = Get-Culture | Select-Object -ExpandProperty IetfLanguageTag
        Write-Debug "System locale detected: $systemLocale"

        # Map system locale to supported language (fuzzy match for Chinese)
        $defaultLang = 'en'
        foreach ($lang in $languages) {
            if ($lang.Code -eq 'en') { continue }
            if ($systemLocale -like "$($lang.Code)*" -or $systemLocale -like "*$($lang.Code)*") {
                $defaultLang = $lang.Code
                Write-Debug "Matched system locale to: $($lang.Code)"
                break
            }
        }

        # Auto-apply default language if not English
        if ($defaultLang -ne 'en') {
            Write-Debug "Auto-applying default language: $defaultLang"
            Set-WinUtilLanguage -Code $defaultLang
            # Download locale if needed
            $null = Get-WinUtilLocale -Code $defaultLang
            if ($null -ne $sync.uiTranslations) {
                Set-WinUtilLanguageUI
            }
            Rebuild-PanelsWithLanguage
        }

        # Get LanguageMenu from Form (Menu control)
        $langMenu = $sync["Form"].FindName("LanguageMenu")
        if ($null -eq $langMenu) {
            Write-Warning "LanguageMenu not found in XAML"
            return
        }

        # Clear existing menu items (except header and separator at index 0,1)
        while ($langMenu.Items.Count -gt 2) {
            $langMenu.Items.RemoveAt(2)
        }

        # Add menu items for each language
        foreach ($lang in $languages) {
            $menuItem = New-Object System.Windows.Controls.MenuItem
            $menuItem.Header = $lang.Name
            $menuItem.Tag = $lang.Code
            $menuItem.FontSize = 14

            if ($lang.Code -eq 'en') {
                $menuItem.Header = "English (Default)"
            }

            $menuItem.Add_Click({
                param($sender)
                $langCode = $sender.Tag
                Write-Debug "Language switch requested: $langCode"

                # Apply language
                Set-WinUtilLanguage -Code $langCode

                # Update UI if not English
                if ($langCode -ne 'en') {
                    Set-WinUtilLanguageUI
                }

                # Rebuild panels with new language
                Rebuild-PanelsWithLanguage
            })

            $langMenu.Items.Add($menuItem)
        }
    }
}

function Rebuild-PanelsWithLanguage {
    <#
    .SYNOPSIS
    Rebuilds UI panels after language switch while preserving checkbox states
    #>
    [CmdletBinding()]
    param()

    process {
        # Save current checkbox states
        $checkboxStates = @{}
        $sync.configs.applicationsHashtable.Keys | ForEach-Object {
            $key = $_
            $checkbox = $sync["$($_)checkbox"]
            if ($checkbox) {
                $checkboxStates[$key] = $checkbox.IsChecked
            }
        }

        # Rebuild UI elements
        Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
        Initialize-WPFUI -targetGridName "appscategory"
        Initialize-WPFUI -targetGridName "appspanel"
        Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2
        Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2

        # Restore checkbox states
        foreach ($key in $checkboxStates.Keys) {
            $checkbox = $sync["$($key)checkbox"]
            if ($checkbox) {
                $checkbox.IsChecked = $checkboxStates[$key]
            }
        }

        # Re-bind button click handlers
        # Copy keys to array first to avoid enumeration issues during modification
        $keysToProcess = @($sync.keys)
        foreach ($key in $keysToProcess) {
            if ($sync[$key]) {
                $typeName = ($sync[$key].GetType() | Select-Object -ExpandProperty Name)

                if ($typeName -eq "Button" -and $key -notmatch "MenuItem|Popup") {
                    # Skip already bound buttons
                    $handlerName = "Bound_$($key)"
                    if (-not $sync[$handlerName]) {
                        $sync[$key].Add_Click({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFButton $Sender.name
                        })
                        $sync[$handlerName] = $true
                    }
                }
            }
        }

        Write-Debug "Panels rebuilt with language: $($sync.currentLocale)"
    }
}
