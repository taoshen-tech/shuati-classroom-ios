source 'https://cdn.cocoapods.org/'
platform :ios, '15.0'
project 'ShuaTiClassroom.xcodeproj'

target 'ShuaTiClassroom' do
  use_frameworks! :linkage => :static
  pod 'MobileVLCKit', '3.7.5'

  target 'ShuaTiClassroomTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      config.build_settings['ENABLE_BITCODE'] = 'NO'
    end
  end
end
