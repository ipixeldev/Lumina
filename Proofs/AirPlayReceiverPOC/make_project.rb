# frozen_string_literal: true

require "fileutils"
require "digest"
gem "xcodeproj", "= 1.27.0"
require "xcodeproj"

root = File.expand_path(__dir__)
project_path = File.join(root, "AirPlayReceiverPOC.xcodeproj")
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2610"
project.root_object.attributes["LastUpgradeCheck"] = "2610"

main_group = project.main_group
sources_group = main_group.new_group("AirPlayReceiverPOC", "AirPlayReceiverPOC")
tests_group = main_group.new_group("AirPlayReceiverPOCTests", "AirPlayReceiverPOCTests")
configuration_group = main_group.new_group("Configuration")
signing_configuration = configuration_group.new_file("../../Configuration/Signing.xcconfig")

app = project.new_target(:application, "AirPlayReceiverPOC", :osx, "14.0")
tests = project.new_target(:unit_test_bundle, "AirPlayReceiverPOCTests", :osx, "14.0")
tests.add_dependency(app)

# xcodeproj 1.27 points Cocoa.framework at the Xcode 16 SDK by default. Use
# SDKROOT so the generated project follows the selected Xcode installation.
cocoa_framework = project.files.find { |file| file.display_name == "Cocoa.framework" }
if cocoa_framework
  cocoa_framework.source_tree = "SDKROOT"
  cocoa_framework.path = "System/Library/Frameworks/Cocoa.framework"
end

Dir.glob(File.join(root, "AirPlayReceiverPOC", "**", "*.swift")).sort.each do |path|
  reference = sources_group.new_file(path.delete_prefix("#{root}/AirPlayReceiverPOC/"))
  app.source_build_phase.add_file_reference(reference)
end

Dir.glob(File.join(root, "AirPlayReceiverPOCTests", "**", "*.swift")).sort.each do |path|
  reference = tests_group.new_file(path.delete_prefix("#{root}/AirPlayReceiverPOCTests/"))
  tests.source_build_phase.add_file_reference(reference)
end

app.build_configurations.each do |configuration|
  configuration.base_configuration_reference = signing_configuration
  settings = configuration.build_settings
  settings["CODE_SIGN_ENTITLEMENTS"] = "AirPlayReceiverPOC/AirPlayReceiverPOC.entitlements"
  settings["COMBINE_HIDPI_IMAGES"] = "YES"
  settings["CURRENT_PROJECT_VERSION"] = "1"
  settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "AirPlayReceiverPOC/Info.plist"
  settings["MARKETING_VERSION"] = "0.1"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.ipixeldev.Lumina.AirPlayReceiverPOC"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  settings["SWIFT_VERSION"] = "6.0"
end

tests.build_configurations.each do |configuration|
  configuration.base_configuration_reference = signing_configuration
  settings = configuration.build_settings
  settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.ipixeldev.Lumina.AirPlayReceiverPOCTests"
  settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  settings["SWIFT_VERSION"] = "6.0"
  settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/AirPlayReceiverPOC.app/Contents/MacOS/AirPlayReceiverPOC"
end

project.predictabilize_uuids

# xcodeproj 1.27 does not assign stable IDs to this mutually-referencing pair.
# Pin the generated dependency objects so regenerating the project is clean.
dependency = tests.dependencies.first
dependency_proxy = dependency&.target_proxy
raise "Missing generated test dependency" unless dependency && dependency_proxy

objects_by_uuid = project.objects_by_uuid
{
  dependency => Digest::MD5.hexdigest("AirPlayReceiverPOCTests/AirPlayReceiverPOC/dependency").upcase,
  dependency_proxy => Digest::MD5.hexdigest("AirPlayReceiverPOCTests/AirPlayReceiverPOC/proxy").upcase,
}.each do |object, stable_uuid|
  objects_by_uuid.delete(object.uuid)
  object.instance_variable_set(:@uuid, stable_uuid)
  objects_by_uuid[stable_uuid] = object
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(project_path, "AirPlayReceiverPOC", true)

puts "Generated #{project_path}"
