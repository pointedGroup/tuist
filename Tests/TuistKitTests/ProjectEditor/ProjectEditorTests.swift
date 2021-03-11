import Foundation
import TSCBasic
import TuistCore
import TuistGraph
import TuistGraphTesting
import TuistLoader
import TuistPlugin
import TuistPluginTesting
import TuistSupport
import XCTest

@testable import TuistCoreTesting
@testable import TuistGeneratorTesting
@testable import TuistKit
@testable import TuistLoaderTesting
@testable import TuistScaffoldTesting
@testable import TuistSupportTesting

final class ProjectEditorErrorTests: TuistUnitTestCase {
    func test_type() {
        XCTAssertEqual(ProjectEditorError.noEditableFiles(AbsolutePath.root).type, .abort)
    }

    func test_description() {
        XCTAssertEqual(ProjectEditorError.noEditableFiles(AbsolutePath.root).description, "There are no editable files at \(AbsolutePath.root.pathString)")
    }
}

final class ProjectEditorTests: TuistUnitTestCase {
    var generator: MockDescriptorGenerator!
    var projectEditorMapper: MockProjectEditorMapper!
    var resourceLocator: MockResourceLocator!
    var manifestFilesLocator: MockManifestFilesLocator!
    var helpersDirectoryLocator: MockHelpersDirectoryLocator!
    var writer: MockXcodeProjWriter!
    var templatesDirectoryLocator: MockTemplatesDirectoryLocator!
    var configLoader: MockConfigLoader!
    var pluginService: MockPluginService!
    var projectDescriptionHelpersBuilder: MockProjectDescriptionHelpersBuilder!
    var subject: ProjectEditor!

    override func setUp() {
        super.setUp()
        generator = MockDescriptorGenerator()
        projectEditorMapper = MockProjectEditorMapper()
        resourceLocator = MockResourceLocator()
        manifestFilesLocator = MockManifestFilesLocator()
        helpersDirectoryLocator = MockHelpersDirectoryLocator()
        writer = MockXcodeProjWriter()
        templatesDirectoryLocator = MockTemplatesDirectoryLocator()
        configLoader = MockConfigLoader()
        pluginService = MockPluginService()
        projectDescriptionHelpersBuilder = MockProjectDescriptionHelpersBuilder()
        subject = ProjectEditor(
            generator: generator,
            projectEditorMapper: projectEditorMapper,
            resourceLocator: resourceLocator,
            manifestFilesLocator: manifestFilesLocator,
            helpersDirectoryLocator: helpersDirectoryLocator,
            writer: writer,
            templatesDirectoryLocator: templatesDirectoryLocator,
            configLoader: configLoader,
            pluginService: pluginService,
            projectDescriptionHelpersBuilder: projectDescriptionHelpersBuilder
        )
    }

    override func tearDown() {
        super.tearDown()
        generator = nil
        projectEditorMapper = nil
        resourceLocator = nil
        manifestFilesLocator = nil
        helpersDirectoryLocator = nil
        templatesDirectoryLocator = nil
        subject = nil
    }

    func test_edit() throws {
        // Given
        let directory = try temporaryPath()
        let projectDescriptionPath = directory.appending(component: "ProjectDescription.framework")
        let graph = ValueGraph.test(name: "Edit")
        let helpersDirectory = directory.appending(component: "ProjectDescriptionHelpers")
        try FileHandler.shared.createFolder(helpersDirectory)
        let helpers = ["A.swift", "B.swift"].map { helpersDirectory.appending(component: $0) }
        try helpers.forEach { try FileHandler.shared.touch($0) }
        let manifests: [(Manifest, AbsolutePath)] = [(.project, directory.appending(component: "Project.swift"))]
        let tuistPath = AbsolutePath(ProcessInfo.processInfo.arguments.first!)
        let setupPath = directory.appending(components: "Setup.swift")
        let configPath = directory.appending(components: "Tuist", "Config.swift")
        let dependenciesPath = directory.appending(components: "Tuist", "Dependencies.swif")

        resourceLocator.projectDescriptionStub = { projectDescriptionPath }
        manifestFilesLocator.locateProjectManifestsStub = manifests
        manifestFilesLocator.locateConfigStub = configPath
        manifestFilesLocator.locateDependenciesStub = dependenciesPath
        manifestFilesLocator.locateSetupStub = setupPath
        helpersDirectoryLocator.locateStub = helpersDirectory
        projectEditorMapper.mapStub = graph
        generator.generateWorkspaceStub = { _ in
            .test(xcworkspacePath: directory.appending(component: "Edit.xcworkspacepath"))
        }

        // When
        try _ = subject.edit(at: directory, in: directory)

        // Then
        XCTAssertEqual(projectEditorMapper.mapArgs.count, 1)
        let mapArgs = projectEditorMapper.mapArgs.first
        XCTAssertEqual(mapArgs?.tuistPath, tuistPath)
        XCTAssertEqual(mapArgs?.helpers, helpers)
        XCTAssertEqual(mapArgs?.sourceRootPath, directory)
        XCTAssertEqual(mapArgs?.projectDescriptionPath, projectDescriptionPath)
        XCTAssertEqual(mapArgs?.configPath, configPath)
        XCTAssertEqual(mapArgs?.setupPath, setupPath)
        XCTAssertEqual(mapArgs?.dependenciesPath, dependenciesPath)
    }

    func test_edit_when_there_are_no_editable_files() throws {
        // Given
        let directory = try temporaryPath()
        let projectDescriptionPath = directory.appending(component: "ProjectDescription.framework")
        let graph = ValueGraph.test(name: "Edit")
        let helpersDirectory = directory.appending(component: "ProjectDescriptionHelpers")
        try FileHandler.shared.createFolder(helpersDirectory)

        resourceLocator.projectDescriptionStub = { projectDescriptionPath }
        manifestFilesLocator.locateProjectManifestsStub = []
        manifestFilesLocator.locatePluginManifestsStub = []
        helpersDirectoryLocator.locateStub = helpersDirectory
        projectEditorMapper.mapStub = graph
        generator.generateWorkspaceStub = { _ in
            .test(xcworkspacePath: directory.appending(component: "Edit.xcworkspacepath"))
        }

        // Then
        XCTAssertThrowsSpecific(
            // When
            try subject.edit(at: directory, in: directory), ProjectEditorError.noEditableFiles(directory)
        )
    }

    func test_edit_with_plugin() throws {
        // Given
        let directory = try temporaryPath()
        let projectDescriptionPath = directory.appending(component: "ProjectDescription.framework")
        let graph = ValueGraph.test(name: "Edit")
        let pluginManifest = directory.appending(component: "Plugin.swift")
        let tuistPath = AbsolutePath(ProcessInfo.processInfo.arguments.first!)

        // When
        resourceLocator.projectDescriptionStub = { projectDescriptionPath }
        manifestFilesLocator.locatePluginManifestsStub = [pluginManifest]

        projectEditorMapper.mapStub = graph
        generator.generateWorkspaceStub = { _ in
            .test(xcworkspacePath: directory.appending(component: "Edit.xcworkspace"))
        }

        // When
        try _ = subject.edit(at: directory, in: directory)

        // Then
        XCTAssertEqual(projectEditorMapper.mapArgs.count, 1)
        let mapArgs = projectEditorMapper.mapArgs.first
        XCTAssertEqual(mapArgs?.tuistPath, tuistPath)
        XCTAssertEqual(mapArgs?.sourceRootPath, directory)
        XCTAssertEqual(mapArgs?.projectDescriptionPath, projectDescriptionPath)
        XCTAssertEqual(mapArgs?.editablePluginManifests.map(\.1), [pluginManifest])
        XCTAssertEqual(mapArgs?.builtPluginHelperModules, [])
    }

    func test_edit_with_many_plugins() throws {
        // Given
        let directory = try temporaryPath()
        let projectDescriptionPath = directory.appending(component: "ProjectDescription.framework")
        let graph = ValueGraph.test(name: "Edit")
        let pluginManifests = [
            directory.appending(components: "A", "Plugin.swift"),
            directory.appending(components: "B", "Plugin.swift"),
            directory.appending(components: "C", "Plugin.swift"),
            directory.appending(components: "D", "Plugin.swift"),
        ]
        let tuistPath = AbsolutePath(ProcessInfo.processInfo.arguments.first!)

        // When
        resourceLocator.projectDescriptionStub = { projectDescriptionPath }
        manifestFilesLocator.locatePluginManifestsStub = pluginManifests

        projectEditorMapper.mapStub = graph
        generator.generateWorkspaceStub = { _ in
            .test(xcworkspacePath: directory.appending(component: "Edit.xcworkspacepath"))
        }

        // When
        try _ = subject.edit(at: directory, in: directory)

        // Then
        XCTAssertEqual(projectEditorMapper.mapArgs.count, 1)
        let mapArgs = projectEditorMapper.mapArgs.first
        XCTAssertEqual(mapArgs?.tuistPath, tuistPath)
        XCTAssertEqual(mapArgs?.sourceRootPath, directory)
        XCTAssertEqual(mapArgs?.projectDescriptionPath, projectDescriptionPath)
        XCTAssertEqual(mapArgs?.editablePluginManifests.map(\.1), pluginManifests)
        XCTAssertEqual(mapArgs?.builtPluginHelperModules, [])
    }

    func test_edit_project_with_local_plugin() throws {
        // Given
        let directory = try temporaryPath()
        let projectDescriptionPath = directory.appending(component: "ProjectDescription.framework")
        let graph = ValueGraph.test(name: "Edit")

        // Project
        let manifests: [(Manifest, AbsolutePath)] = [(.project, directory.appending(component: "Project.swift"))]

        // Local plugin
        let pluginDirectory = directory.appending(component: "Plugin")
        let pluginHelpersDirectory = pluginDirectory.appending(component: "ProjectDescriptionHelpers")
        try FileHandler.shared.createFolder(pluginDirectory)
        try FileHandler.shared.createFolder(pluginHelpersDirectory)
        let pluginManifestPath = pluginDirectory.appending(component: "Plugin.swift")
        try FileHandler.shared.touch(pluginManifestPath)

        let tuistPath = AbsolutePath(ProcessInfo.processInfo.arguments.first!)

        resourceLocator.projectDescriptionStub = { projectDescriptionPath }
        manifestFilesLocator.locateProjectManifestsStub = manifests
        manifestFilesLocator.locatePluginManifestsStub = [pluginManifestPath]
        projectEditorMapper.mapStub = graph
        generator.generateWorkspaceStub = { _ in
            .test(xcworkspacePath: directory.appending(component: "Edit.xcworkspacepath"))
        }

        configLoader.loadConfigStub = { _ in
            .test(plugins: [.local(path: pluginManifestPath.pathString)])
        }

        pluginService.loadPluginsStub = { _ in
            .test(projectDescriptionHelpers: [ProjectDescriptionHelpersPlugin(name: "LocalPlugin", path: pluginHelpersDirectory)])
        }

        // When
        try _ = subject.edit(at: directory, in: directory)

        // Then
        XCTAssertEqual(projectEditorMapper.mapArgs.count, 1)
        let mapArgs = projectEditorMapper.mapArgs.first
        XCTAssertEqual(mapArgs?.tuistPath, tuistPath)
        XCTAssertEqual(mapArgs?.sourceRootPath, directory)
        XCTAssertEqual(mapArgs?.projectDescriptionPath, projectDescriptionPath)
        XCTAssertEqual(mapArgs?.editablePluginManifests.map(\.0), ["LocalPlugin"])
        XCTAssertEqual(mapArgs?.editablePluginManifests.map(\.1), [pluginManifestPath])
        XCTAssertEqual(mapArgs?.builtPluginHelperModules, [])
    }

    func test_edit_project_with_remote_plugin() throws {
        // Given
        let directory = try temporaryPath()
        let projectDescriptionPath = directory.appending(component: "ProjectDescription.framework")
        let graph = ValueGraph.test(name: "Edit")

        // Project
        let manifests: [(Manifest, AbsolutePath)] = [(.project, directory.appending(component: "Project.swift"))]
        let tuistPath = AbsolutePath(ProcessInfo.processInfo.arguments.first!)

        resourceLocator.projectDescriptionStub = { projectDescriptionPath }
        manifestFilesLocator.locateProjectManifestsStub = manifests
        manifestFilesLocator.locatePluginManifestsStub = []
        projectEditorMapper.mapStub = graph
        generator.generateWorkspaceStub = { _ in
            .test(xcworkspacePath: directory.appending(component: "Edit.xcworkspacepath"))
        }

        configLoader.loadConfigStub = { _ in
            .test(plugins: [.gitWithTag(url: "https://git/repo/plugin", tag: "1.0.0")])
        }

        pluginService.loadPluginsStub = { _ in
            .test(projectDescriptionHelpers: [ProjectDescriptionHelpersPlugin(name: "RemotePlugin", path: AbsolutePath("/Some/Path/To/Plugin"))])
        }

        projectDescriptionHelpersBuilder.buildPluginsStub = { _, _, plugins in
            plugins.map { ProjectDescriptionHelpersModule(name: $0.name, path: $0.path) }
        }

        // When
        try _ = subject.edit(at: directory, in: directory)

        // Then
        XCTAssertEqual(projectEditorMapper.mapArgs.count, 1)
        let mapArgs = projectEditorMapper.mapArgs.first
        XCTAssertEqual(mapArgs?.tuistPath, tuistPath)
        XCTAssertEqual(mapArgs?.sourceRootPath, directory)
        XCTAssertEqual(mapArgs?.projectDescriptionPath, projectDescriptionPath)
        XCTAssertEmpty(try XCTUnwrap(mapArgs?.editablePluginManifests))
        XCTAssertEqual(mapArgs?.builtPluginHelperModules, [ProjectDescriptionHelpersModule(name: "RemotePlugin", path: AbsolutePath("/Some/Path/To/Plugin"))])
    }
}
