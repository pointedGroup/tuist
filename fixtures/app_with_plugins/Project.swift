import ProjectDescription
import ProjectDescriptionHelpers

import LocalPlugin
import PluginFixture
import ExampleTuistPlugin

// Test plugins are loaded
let localHelper = LocalHelper(name: "LocalPlugin")
let remoteHelper = RemoteHelper(name: "RemotePlugin")
let externalLocalHelper = Project.helper

let project = Project.app(
    name: "TuistPluginTest",
    platform: .iOS,
    additionalTargets: ["TuistPluginTestKit", "TuistPluginTestUI"]
)
