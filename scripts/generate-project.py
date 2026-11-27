#!/usr/bin/env python3
"""Generate the small, dependency-free Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent

def uid(label): return hashlib.sha256(label.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
objects = {}
def obj(name, body):
    objects[uid(name)] = body
    return uid(name)

sources = sorted((ROOT / 'NearChat').rglob('*.swift'))
files = []
builds = []
for path in sources:
    relative = path.relative_to(ROOT).as_posix()
    ref = obj('ref:' + relative, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(relative)}; sourceTree = SOURCE_ROOT;')
    files.append(ref)
    builds.append(obj('build:' + relative, f'isa = PBXBuildFile; fileRef = {ref};'))
resources = []
for relative in ['NearChat/Resources/Info.plist', 'NearChat/Resources/PrivacyInfo.xcprivacy']:
    ref = obj('ref:' + relative, f'isa = PBXFileReference; lastKnownFileType = text.xml; path = {q(relative)}; sourceTree = SOURCE_ROOT;')
    files.append(ref)
    if relative.endswith('xcprivacy'):
        resources.append(obj('build:' + relative, f'isa = PBXBuildFile; fileRef = {ref};'))
product = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = NearChat.app; sourceTree = BUILT_PRODUCTS_DIR;')
package = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = ".";')
packageProduct = obj('package-product', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = NearChatCore;')
packageBuild = obj('package-build', f'isa = PBXBuildFile; productRef = {packageProduct};')
products = obj('products', f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
appGroup = obj('appgroup', f'isa = PBXGroup; children = ({",".join(files)},); name = NearChat; sourceTree = "<group>";')
coreRefs = []
for path in [ROOT / 'Package.swift', *sorted((ROOT / 'Sources').rglob('*.swift')), *sorted((ROOT / 'Tests').rglob('*.swift'))]:
    relative = path.relative_to(ROOT).as_posix()
    coreRefs.append(obj('ref:' + relative, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(relative)}; sourceTree = SOURCE_ROOT;'))
coreGroup = obj('coregroup', f'isa = PBXGroup; children = ({",".join(coreRefs)},); name = "Core and tests (Swift Package)"; sourceTree = "<group>";')
main = obj('main', f'isa = PBXGroup; children = ({appGroup},{coreGroup},{products},); sourceTree = "<group>";')
sourcesPhase = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({packageBuild},); runOnlyForDeploymentPostprocessing = 0;')
resourcesPhase = obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resources)},); runOnlyForDeploymentPostprocessing = 0;')
projectConfigs = []
targetConfigs = []
for config in ['Debug', 'Release']:
    projectSettings = {'CLANG_ENABLE_MODULES': 'YES', 'SWIFT_VERSION': '5.0', 'IPHONEOS_DEPLOYMENT_TARGET': '26.0', 'SDKROOT': 'iphoneos', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym'}
    if config == 'Debug':
        projectSettings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        projectSettings['ONLY_ACTIVE_ARCH'] = 'YES'
    targetSettings = {'PRODUCT_NAME': 'NearChat', 'PRODUCT_BUNDLE_IDENTIFIER': 'local.nearchat.lab', 'INFOPLIST_FILE': 'NearChat/Resources/Info.plist', 'CODE_SIGN_STYLE': 'Automatic', 'TARGETED_DEVICE_FAMILY': '1', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'GENERATE_INFOPLIST_FILE': 'NO', 'SWIFT_EMIT_LOC_STRINGS': 'YES', 'MARKETING_VERSION': '0.1', 'CURRENT_PROJECT_VERSION': '1', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks'}
    for category, settings, dest in [('project', projectSettings, projectConfigs), ('target', targetSettings, targetConfigs)]:
        values = ' '.join(f'{k} = {q(v)};' for k, v in settings.items())
        dest.append(obj(f'{category}:{config}', f'isa = XCBuildConfiguration; buildSettings = {{ {values} }}; name = {config};'))
projectList = obj('project-configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(projectConfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
targetList = obj('target-configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(targetConfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {targetList}; buildPhases = ({sourcesPhase},{frameworks},{resourcesPhase},); buildRules = (); dependencies = (); name = NearChat; packageProductDependencies = ({packageProduct},); productName = NearChat; productReference = {product}; productType = "com.apple.product-type.application";')
project = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2630; TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 26.3; }}; }}; }}; buildConfigurationList = {projectList}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ru; hasScannedForEncodings = 0; knownRegions = (ru,en,Base,); mainGroup = {main}; packageReferences = ({package},); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
text = '// !$*UTF8*$!\n{\n archiveVersion = 1;\n classes = {};\n objectVersion = 56;\n objects = {\n'
text += ''.join(f'  {ident} = {{ {body} }};\n' for ident, body in objects.items())
text += f' }};\n rootObject = {project};\n}}\n'
projectDir = ROOT / 'NearChat.xcodeproj'
projectDir.mkdir(exist_ok=True)
(projectDir / 'project.pbxproj').write_text(text)
schemeDir = projectDir / 'xcshareddata/xcschemes'
schemeDir.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NearChat.app" BlueprintName="NearChat" ReferencedContainer="container:NearChat.xcodeproj"/>'
(schemeDir / 'NearChat.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(projectDir)
