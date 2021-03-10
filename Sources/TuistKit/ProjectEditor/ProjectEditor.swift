import Foundation
import TSCBasic
import TuistCore
import TuistGenerator
import TuistGraph
import TuistLoader
import TuistPlugin
import TuistScaffold
import TuistSupport

enum ProjectEditorError: FatalError, Equatable {
    /// This error is thrown when we try to edit in a project in a directory that has no editable files.
    case noEditableFiles(AbsolutePath)

    var type: ErrorType {
        switch self {
        case .noEditableFiles: return .abort
        }
    }

    var description: String {
        switch self {
        case let .noEditableFiles(path):
            return "There are no editable files at \(path.pathString)"
        }
    }
}

protocol ProjectEditing: AnyObject {
    /// Generates an Xcode project to edit the Project defined in the given directory.
    /// - Parameters:
    ///   - editingPath: Directory whose project will be edited.
    ///   - destinationDirectory: Directory in which the Xcode project will be generated.
    /// - Returns: The path to the generated Xcode project.
    func edit(at editingPath: AbsolutePath, in destinationDirectory: AbsolutePath) throws -> AbsolutePath
}

final class ProjectEditor: ProjectEditing {
    /// Project generator.
    let generator: DescriptorGenerating

    /// Project editor mapper.
    let projectEditorMapper: ProjectEditorMapping

    /// Utility to locate Tuist's resources.
    let resourceLocator: ResourceLocating

    /// Utility to locate manifest files.
    let manifestFilesLocator: ManifestFilesLocating

    /// Utility to locate the helpers directory.
    let helpersDirectoryLocator: HelpersDirectoryLocating

    /// Utility to locate the custom templates directory
    let templatesDirectoryLocator: TemplatesDirectoryLocating

    /// Model loader for loading config manifest used to load plugins.
    let configLoader: ConfigLoading

    /// Service for loading plugins that are used when generating the edit project.
    let pluginService: PluginServicing

    /// Builder used to compile and build the loaded plugins
    let projectDescriptionHelpersBuilder: ProjectDescriptionHelpersBuilding

    /// Xcode Project writer
    private let writer: XcodeProjWriting

    init(
        generator: DescriptorGenerating = DescriptorGenerator(),
        projectEditorMapper: ProjectEditorMapping = ProjectEditorMapper(),
        resourceLocator: ResourceLocating = ResourceLocator(),
        manifestFilesLocator: ManifestFilesLocating = ManifestFilesLocator(),
        helpersDirectoryLocator: HelpersDirectoryLocating = HelpersDirectoryLocator(),
        writer: XcodeProjWriting = XcodeProjWriter(),
        templatesDirectoryLocator: TemplatesDirectoryLocating = TemplatesDirectoryLocator(),
        configLoader: ConfigLoading = ConfigLoader(manifestLoader: ManifestLoader()),
        pluginService: PluginServicing = PluginService(),
        projectDescriptionHelpersBuilder: ProjectDescriptionHelpersBuilding = ProjectDescriptionHelpersBuilder()
    ) {
        self.generator = generator
        self.projectEditorMapper = projectEditorMapper
        self.resourceLocator = resourceLocator
        self.manifestFilesLocator = manifestFilesLocator
        self.helpersDirectoryLocator = helpersDirectoryLocator
        self.writer = writer
        self.templatesDirectoryLocator = templatesDirectoryLocator
        self.configLoader = configLoader
        self.pluginService = pluginService
        self.projectDescriptionHelpersBuilder = projectDescriptionHelpersBuilder
    }

    func edit(at editingPath: AbsolutePath, in destinationDirectory: AbsolutePath) throws -> AbsolutePath {
        let projectDescriptionPath = try resourceLocator.projectDescription()
        let projectManifests = manifestFilesLocator.locateProjectManifests(at: editingPath)
        let configPath = manifestFilesLocator.locateConfig(at: editingPath)
        let dependenciesPath = manifestFilesLocator.locateDependencies(at: editingPath)
        let setupPath = manifestFilesLocator.locateSetup(at: editingPath)

        let helpers = helpersDirectoryLocator.locate(at: editingPath).map {
            FileHandler.shared.glob($0, glob: "**/*.swift")
        } ?? []

        let templates = templatesDirectoryLocator.locateUserTemplates(at: editingPath).map {
            FileHandler.shared.glob($0, glob: "**/*.swift") + FileHandler.shared.glob($0, glob: "**/*.stencil")
        } ?? []

        let plugins = loadPlugins(at: editingPath)
        let editablePluginManifests = locateEditablePluginManifests(at: editingPath, plugins: plugins)
        let builtPluginHelperModules = buildPluginModules(
            in: editingPath,
            projectDescriptionPath: projectDescriptionPath,
            editablePluginManifestPaths: editablePluginManifests.map(\.1),
            plugins: plugins
        )

        /// We error if the user tries to edit a project in a directory where there are no editable files.
        if projectManifests.isEmpty, editablePluginManifests.isEmpty, helpers.isEmpty, templates.isEmpty {
            throw ProjectEditorError.noEditableFiles(editingPath)
        }

        // To be sure that we are using the same binary of Tuist that invoked `edit`
        let tuistPath = AbsolutePath(TuistCommand.processArguments()!.first!)
        let workspaceName = "Manifests"

        let graph = try projectEditorMapper.map(
            name: workspaceName,
            tuistPath: tuistPath,
            sourceRootPath: editingPath,
            destinationDirectory: destinationDirectory,
            setupPath: setupPath,
            configPath: configPath,
            dependenciesPath: dependenciesPath,
            projectManifests: projectManifests.map(\.1),
            editablePluginManifests: editablePluginManifests,
            builtPluginHelperModules: builtPluginHelperModules,
            helpers: helpers,
            templates: templates,
            projectDescriptionPath: projectDescriptionPath
        )

        let graphTraverser = ValueGraphTraverser(graph: graph)
        let descriptor = try generator.generateWorkspace(graphTraverser: graphTraverser)
        try writer.write(workspace: descriptor)
        return descriptor.xcworkspacePath
    }

    /// Attempts to load the plugins at the given path. If unable to find the Config manifest
    /// displays a warning to the user.
    /// - Returns: The loaded `Plugins`.
    private func loadPlugins(at path: AbsolutePath) -> Plugins {
        do {
            let config = try configLoader.loadConfig(path: path)
            return try pluginService.loadPlugins(using: config)
        } catch {
            logger.warning("Failed to load plugins, attempt to fix the Config manifest and rerun the command. Continuing...")
            logger.debug("Failed to load plugins during edit: \(error.localizedDescription)")
            return .none
        }
    }

    /// - Returns: A list of manifest name and path for plugin manifests that are editable and should be
    /// loaded as a target in the generated project.
    private func locateEditablePluginManifests(at path: AbsolutePath, plugins: Plugins) -> [(String, AbsolutePath)] {
        let editingPluginManifests = manifestFilesLocator.locatePluginManifests(at: path)
        let loadedHelpers = plugins.projectDescriptionHelpers

        // If a loaded plugin is also a locally editable plugin, we should take the name of the loaded plugin (defined in Plugin.swift manifest)
        // Otherwise, use the name of the parent directory as the name of the plugin.
        return editingPluginManifests.map { editableManifest in
            if let loadedEditableManifest = loadedHelpers.first(where: { $0.path.parentDirectory == editableManifest.parentDirectory }) {
                return (loadedEditableManifest.name, editableManifest)
            } else {
                return (editableManifest.parentDirectory.basename, editableManifest)
            }
        }
    }

    /// Attempts to build the loaded plugins. If it fails, shows a warning to the user.
    /// - Returns: The built plugin helper modules.
    private func buildPluginModules(
        in path: AbsolutePath,
        projectDescriptionPath: AbsolutePath,
        editablePluginManifestPaths: [AbsolutePath],
        plugins: Plugins
    ) -> [ProjectDescriptionHelpersModule] {
        let loadedPluginHelpers = plugins.projectDescriptionHelpers.filter { loadedHelper in
            !editablePluginManifestPaths.contains(where: { $0.parentDirectory == loadedHelper.path.parentDirectory })
        }

        do {
            let builtPluginHelperModules = try projectDescriptionHelpersBuilder.buildPlugins(
                at: path,
                projectDescriptionSearchPaths: ProjectDescriptionSearchPaths.paths(for: projectDescriptionPath),
                projectDescriptionHelperPlugins: loadedPluginHelpers
            )
            return builtPluginHelperModules
        } catch {
            logger.warning("Failed to build plugins, attempt to fix the plugins and rerun the command. Continuing...")
            logger.debug("Failed to build plugins during edit: \(error.localizedDescription)")
            return []
        }
    }
}
