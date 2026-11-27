#!/usr/bin/env python3
"""Create an isolated Xcode UI-test runner; leave NearChat.xcodeproj untouched."""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

repo = Path(__file__).resolve().parent.parent
output = repo / '.build' / 'device-ui-harness'
project = output / 'NearChatDeviceTests.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
main_project = (repo / 'NearChat.xcodeproj/project.pbxproj').read_text()
team = os.environ.get('NEARCHAT_TEST_TEAM')
if not team:
    match = re.search(r'DEVELOPMENT_TEAM = ([A-Z0-9]+);', main_project)
    if not match:
        raise SystemExit('Set NEARCHAT_TEST_TEAM to the app signing team')
    team = match.group(1)
objects = {}
def uid(name):
    return hashlib.sha256(('NearChatDeviceTests:' + name).encode()).hexdigest()[:24].upper()
def add(label, isa, **values):
    identifier = uid(label)
    objects[identifier] = dict(isa=isa, **values)
    return identifier
source = add('source', 'PBXFileReference', lastKnownFileType='sourcecode.swift',
    path=str(repo / 'Tests/NearChatUITests/DeviceSmokeTests.swift'), sourceTree='<absolute>')
product = add('product', 'PBXFileReference', explicitFileType='wrapper.cfbundle',
    path='NearChatDeviceTests.xctest', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex='0')
build = add('source-build', 'PBXBuildFile', fileRef=source)
sources = add('sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=[build], runOnlyForDeploymentPostprocessing='0')
frameworks = add('frameworks', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
resources = add('resources', 'PBXResourcesBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
configs = []
for name in ['Debug', 'Release']:
    settings = dict(CODE_SIGN_STYLE='Automatic', DEVELOPMENT_TEAM=team, ALWAYS_SEARCH_USER_PATHS='NO',
        GENERATE_INFOPLIST_FILE='YES', IPHONEOS_DEPLOYMENT_TARGET='18.6', SDKROOT='iphoneos',
        PRODUCT_BUNDLE_IDENTIFIER='local.nearchat.devicetests', PRODUCT_NAME='$(TARGET_NAME)',
        SWIFT_VERSION='5.0', TARGETED_DEVICE_FAMILY='1', SUPPORTED_PLATFORMS='iphoneos iphonesimulator',
        SWIFT_OPTIMIZATION_LEVEL='-Onone' if name == 'Debug' else '-O')
    configs.append(add('config-' + name, 'XCBuildConfiguration', name=name, buildSettings=settings))
config_list = add('configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
target = add('target', 'PBXNativeTarget', name='NearChatDeviceTests', productName='NearChatDeviceTests',
    productReference=product, productType='com.apple.product-type.bundle.ui-testing',
    buildConfigurationList=config_list, buildPhases=[sources, frameworks, resources], buildRules=[], dependencies=[])
products = add('products', 'PBXGroup', name='Products', children=[product], sourceTree='<group>')
group = add('root-group', 'PBXGroup', children=[source, products], sourceTree='<group>')
project_configs = [add('project-config-' + n, 'XCBuildConfiguration', name=n, buildSettings={}) for n in ['Debug', 'Release']]
project_config_list = add('project-configs', 'XCConfigurationList', buildConfigurations=project_configs,
    defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
root = add('project', 'PBXProject', attributes=dict(LastUpgradeCheck='2630'),
    buildConfigurationList=project_config_list, compatibilityVersion='Xcode 14.0', developmentRegion='ru',
    hasScannedForEncodings='0', knownRegions=['ru', 'en', 'Base'], mainGroup=group,
    productRefGroup=products, projectDirPath='', projectRoot='', targets=[target])
with (project / 'project.pbxproj').open('wb') as file:
    plistlib.dump(dict(archiveVersion='1', classes={}, objectVersion='60', objects=objects, rootObject=root), file, sort_keys=False)
scheme = ET.Element('Scheme', LastUpgradeVersion='2630', version='1.3')
build_action = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
entries = ET.SubElement(build_action, 'BuildActionEntries')
entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='NO', buildForProfiling='NO', buildForArchiving='NO', buildForAnalyzing='YES')
def reference(parent):
    ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=target,
        BuildableName='NearChatDeviceTests.xctest', BlueprintName='NearChatDeviceTests',
        ReferencedContainer='container:NearChatDeviceTests.xcodeproj')
reference(entry)
test = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', shouldUseLaunchSchemeArgsEnv='YES')
testables = ET.SubElement(test, 'Testables')
reference(ET.SubElement(testables, 'TestableReference', skipped='NO', parallelizable='NO'))
scheme_dir = project / 'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)
ET.indent(scheme)
ET.ElementTree(scheme).write(scheme_dir / 'NearChatDeviceTests.xcscheme', encoding='UTF-8', xml_declaration=True)
print(project)
