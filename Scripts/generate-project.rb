require 'fileutils'
require 'digest'

root = ARGV.fetch(0)
Dir.chdir(root)
objects = {}

def serialize(value, level = 0)
  indent = "\t" * level
  case value
  when Hash
    "{\n" + value.map { |key, item| "#{indent}\t#{serialize(key)} = #{serialize(item, level + 1)};\n" }.join + "#{indent}}"
  when Array
    "(\n" + value.map { |item| "#{indent}\t#{serialize(item, level + 1)},\n" }.join + "#{indent})"
  when Integer then value.to_s
  else
    '"' + value.to_s.gsub(/[\\"]/) { |m| '\\' + m } + '"'
  end
end

add = lambda do |key, isa, attrs = {}|
  id = Digest::SHA256.hexdigest(key)[0, 24].upcase
  abort "Duplicate object #{key}" if objects.key?(id)
  objects[id] = { 'isa' => isa }.merge(attrs)
  id
end

ref = lambda do |path, type, tree = 'SOURCE_ROOT'|
  add.call("ref:#{path}", 'PBXFileReference',
           'lastKnownFileType' => type, 'name' => File.basename(path), 'path' => path, 'sourceTree' => tree)
end

phase = lambda do |name, isa, entries|
  ids = entries.map { |file| add.call("build:#{name}:#{file}", 'PBXBuildFile', 'fileRef' => file) }
  add.call("phase:#{name}", isa, 'buildActionMask' => 2147483647, 'files' => ids, 'runOnlyForDeploymentPostprocessing' => 0)
end

config = lambda do |name, debug, release|
  ids = [['Debug', debug], ['Release', release]].map do |mode, settings|
    add.call("config:#{name}:#{mode}", 'XCBuildConfiguration', 'buildSettings' => settings, 'name' => mode)
  end
  add.call("config-list:#{name}", 'XCConfigurationList',
           'buildConfigurations' => ids, 'defaultConfigurationIsVisible' => 0, 'defaultConfigurationName' => 'Debug')
end

project_id = Digest::SHA256.hexdigest('project')[0, 24].upcase
app_id = Digest::SHA256.hexdigest('target:app')[0, 24].upcase
test_id = Digest::SHA256.hexdigest('target:test')[0, 24].upcase
swift_refs = Dir.glob('Sources/**/*.swift').sort.map { |path| ref.call(path, 'sourcecode.swift') }
test_refs = Dir.glob('Tests/**/*.swift').sort.map { |path| ref.call(path, 'sourcecode.swift') }
resource_refs = Dir.glob('Resources/*').sort.map { |path| ref.call(path, 'file') }
reference_refs = Dir.glob('Reference/*').sort.map { |path| ref.call(path, 'text') }
readme = ref.call('README.md', 'net.daringfireball.markdown')

app_product = add.call('app-product', 'PBXFileReference',
                       'explicitFileType' => 'wrapper.application', 'path' => 'Fawaly Rebuilt.app', 'sourceTree' => 'BUILT_PRODUCTS_DIR')
test_product = add.call('test-product', 'PBXFileReference',
                        'explicitFileType' => 'wrapper.cfbundle', 'path' => 'FawalyRebuiltTests.xctest', 'sourceTree' => 'BUILT_PRODUCTS_DIR')
groups = [['Sources', swift_refs], ['Resources', resource_refs], ['Tests', test_refs], ['Reference', reference_refs], ['Products', [app_product, test_product]]].to_h do |name, files|
  [name, add.call("group:#{name}", 'PBXGroup', 'children' => files, 'name' => name, 'sourceTree' => '<group>')]
end
main_group = add.call('main-group', 'PBXGroup', 'children' => groups.values + [readme], 'sourceTree' => '<group>')

common = {
  'SDKROOT' => 'macosx', 'MACOSX_DEPLOYMENT_TARGET' => '14.0', 'SWIFT_VERSION' => '5.0',
  'CLANG_ENABLE_MODULES' => 'YES', 'SWIFT_ENABLE_EXPLICIT_MODULES' => 'NO',
  'CODE_SIGN_STYLE' => 'Manual', 'CODE_SIGN_IDENTITY' => '-', 'GENERATE_INFOPLIST_FILE' => 'YES'
}
project_config = config.call('project',
                            common.merge('SWIFT_OPTIMIZATION_LEVEL' => '-Onone', 'ENABLE_TESTABILITY' => 'YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => ['$(inherited)', 'DEBUG']),
                            common.merge('SWIFT_OPTIMIZATION_LEVEL' => '-O'))
app_settings = {
  'PRODUCT_NAME' => 'Fawaly Rebuilt', 'PRODUCT_MODULE_NAME' => 'FawalyApp',
  'ENABLE_DEBUG_DYLIB' => 'NO',
  'PRODUCT_BUNDLE_IDENTIFIER' => 'com.daxow.fawaly.rebuilt', 'MARKETING_VERSION' => '0.7.0',
  'CURRENT_PROJECT_VERSION' => '22', 'INFOPLIST_KEY_CFBundleDisplayName' => 'Sudo Interns',
  'ENABLE_HARDENED_RUNTIME' => 'YES',
  'GENERATE_INFOPLIST_FILE' => 'NO', 'INFOPLIST_FILE' => 'Config/Fawaly-Info.plist',
  'INFOPLIST_KEY_CFBundleIconFile' => 'Fawaly.icns', 'INFOPLIST_KEY_LSApplicationCategoryType' => 'public.app-category.productivity',
  'OTHER_LDFLAGS' => ['$(inherited)', '-lsqlite3'],
  'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks']
}
test_settings = {
  'PRODUCT_NAME' => 'FawalyRebuiltTests', 'PRODUCT_BUNDLE_IDENTIFIER' => 'com.daxow.fawaly.rebuilt.tests',
  'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/Fawaly Rebuilt.app/Contents/MacOS/Fawaly Rebuilt',
  'BUNDLE_LOADER' => '$(TEST_HOST)',
  'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks', '@loader_path/../Frameworks']
}
app_configs = config.call('app', app_settings, app_settings)
test_configs = config.call('test', test_settings, test_settings)

sparkle_package = add.call('package:sparkle', 'XCRemoteSwiftPackageReference',
                           'repositoryURL' => 'https://github.com/sparkle-project/Sparkle',
                           'requirement' => { 'kind' => 'exactVersion', 'version' => '2.10.1' })
sparkle_product = add.call('product:sparkle', 'XCSwiftPackageProductDependency',
                           'package' => sparkle_package, 'productName' => 'Sparkle')
sparkle_link = add.call('build:sparkle-link', 'PBXBuildFile', 'productRef' => sparkle_product)
sparkle_frameworks = add.call('phase:app-frameworks', 'PBXFrameworksBuildPhase',
                              'buildActionMask' => 2147483647, 'files' => [sparkle_link], 'runOnlyForDeploymentPostprocessing' => 0)

app_phases = [
  phase.call('app-sources', 'PBXSourcesBuildPhase', swift_refs),
  sparkle_frameworks,
  phase.call('app-resources', 'PBXResourcesBuildPhase', resource_refs)
]
test_phases = [phase.call('test-sources', 'PBXSourcesBuildPhase', test_refs), phase.call('test-frameworks', 'PBXFrameworksBuildPhase', [])]
proxy = add.call('app-proxy', 'PBXContainerItemProxy', 'containerPortal' => project_id,
                 'proxyType' => 1, 'remoteGlobalIDString' => app_id, 'remoteInfo' => 'Fawaly Rebuilt')
dependency = add.call('app-dependency', 'PBXTargetDependency', 'target' => app_id, 'targetProxy' => proxy)
add.call('target:app', 'PBXNativeTarget',
         'buildConfigurationList' => app_configs, 'buildPhases' => app_phases, 'buildRules' => [], 'dependencies' => [],
         'name' => 'Fawaly Rebuilt', 'productName' => 'Fawaly Rebuilt', 'productReference' => app_product,
         'packageProductDependencies' => [sparkle_product],
         'productType' => 'com.apple.product-type.application')
add.call('target:test', 'PBXNativeTarget',
         'buildConfigurationList' => test_configs, 'buildPhases' => test_phases, 'buildRules' => [], 'dependencies' => [dependency],
         'name' => 'FawalyRebuiltTests', 'productName' => 'FawalyRebuiltTests', 'productReference' => test_product,
         'productType' => 'com.apple.product-type.bundle.unit-test')
add.call('project', 'PBXProject',
         'attributes' => { 'LastUpgradeCheck' => '2700', 'TargetAttributes' => { test_id => { 'TestTargetID' => app_id } } },
         'buildConfigurationList' => project_config, 'compatibilityVersion' => 'Xcode 14.0',
         'developmentRegion' => 'en', 'hasScannedForEncodings' => 0, 'knownRegions' => ['en', 'Base'],
         'mainGroup' => main_group, 'productRefGroup' => groups.fetch('Products'), 'projectDirPath' => '',
         'projectRoot' => '', 'targets' => [app_id, test_id], 'packageReferences' => [sparkle_package])
project = 'Fawaly Rebuilt.xcodeproj'
FileUtils.mkdir_p("#{project}/xcshareddata/xcschemes")
File.write("#{project}/project.pbxproj", "// !$*UTF8*$!\n" + serialize({
  'archiveVersion' => 1, 'classes' => {}, 'objectVersion' => 56, 'objects' => objects, 'rootObject' => project_id
}) + "\n")
app_ref = %(<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{app_id}" BuildableName="Fawaly Rebuilt.app" BlueprintName="Fawaly Rebuilt" ReferencedContainer="container:#{project}"/>)
test_ref = %(<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{test_id}" BuildableName="FawalyRebuiltTests.xctest" BlueprintName="FawalyRebuiltTests" ReferencedContainer="container:#{project}"/>)
File.write("#{project}/xcshareddata/xcschemes/Fawaly Rebuilt.xcscheme", <<~XML)
  <?xml version="1.0" encoding="UTF-8"?>
  <Scheme LastUpgradeVersion="2700" version="1.7">
    <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
        <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">#{app_ref}</BuildActionEntry>
        <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">#{test_ref}</BuildActionEntry>
      </BuildActionEntries>
    </BuildAction>
    <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables><TestableReference skipped="NO">#{test_ref}</TestableReference></Testables>
      <MacroExpansion>#{app_ref}</MacroExpansion>
    </TestAction>
    <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO">
      <BuildableProductRunnable runnableDebuggingMode="0">#{app_ref}</BuildableProductRunnable>
    </LaunchAction>
    <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">#{app_ref}</BuildableProductRunnable>
    </ProfileAction>
    <AnalyzeAction buildConfiguration="Debug"/>
    <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
  </Scheme>
XML
