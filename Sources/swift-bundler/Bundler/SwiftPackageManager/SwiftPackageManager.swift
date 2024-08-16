import Foundation
import Parsing
import StackOtterArgParser
import Version
import Yams

/// A utility for interacting with the Swift package manager and performing some other package
/// related operations.
enum SwiftPackageManager {
  /// Creates a new package using the given directory as the package's root directory.
  /// - Parameters:
  ///   - directory: The package's root directory (will be created if it doesn't exist).
  ///   - name: The name for the package.
  /// - Returns: If an error occurs, a failure is returned.
  static func createPackage(
    in directory: URL,
    name: String
  ) -> Result<Void, SwiftPackageManagerError> {
    // Create the package directory if it doesn't exist
    let createPackageDirectory: () -> Result<Void, SwiftPackageManagerError> = {
      if !FileManager.default.itemExists(at: directory, withType: .directory) {
        do {
          try FileManager.default.createDirectory(at: directory)
        } catch {
          return .failure(.failedToCreatePackageDirectory(directory, error))
        }
      }
      return .success()
    }

    // Run the init command
    let runInitCommand: () -> Result<Void, SwiftPackageManagerError> = {
      let arguments = [
        "package", "init",
        "--type=executable",
        "--name=\(name)",
      ]

      let process = Process.create(
        "swift",
        arguments: arguments,
        directory: directory)
      process.setOutputPipe(Pipe())

      return process.runAndWait()
        .mapError { error in
          .failedToRunSwiftInit(
            command: "swift \(arguments.joined(separator: " "))",
            error
          )
        }
    }

    // Create the configuration file
    let createConfigurationFile: () -> Result<Void, SwiftPackageManagerError> = {
      PackageConfiguration.createConfigurationFile(in: directory, app: name, product: name)
        .mapError { error in
          .failedToCreateConfigurationFile(error)
        }
    }

    // Compose the function
    let create = flatten(
      createPackageDirectory,
      runInitCommand,
      createConfigurationFile)

    return create()
  }

  struct XcodeDestinations: Codable {
    var name: String = ""
    var platform: String? = nil
    var id: String? = nil
    var OS: String? = nil
    var arch: String? = nil
    var variant: String? = nil
    var error: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
      case platform = "platform"
      case name = "name"
      case id = "id"
      case OS = "OS"
      case arch = "arch"
      case variant = "variant"
      case error = "error"
    }

    subscript(_ keyPath: CodingKeys) -> String? {
      get {
        if let data = try? JSONEncoder().encode(self), var dict = try? JSONSerialization.jsonObject(with: data) as? [CodingKeys: String?] {
          return dict[keyPath] ?? nil
        } else {
          return nil
        }
      }

      set {
        if let data = try? JSONEncoder().encode(self), var dict = try? JSONSerialization.jsonObject(with: data) as? [CodingKeys: String?] {
          dict[keyPath] = newValue
          if let newData = try? JSONSerialization.data(withJSONObject: dict), let newObj = try? JSONDecoder().decode(Self.self, from: newData) {
            self = newObj
          }
        }
      }
    }
  }

  /// Builds the specified product of a Swift package.
  /// - Parameters:
  ///   - product: The product to build.
  ///   - packageDirectory: The root directory of the package containing the product.
  ///   - configuration: The build configuration to use.
  ///   - architectures: The set of architectures to build for.
  ///   - platform: The platform to build for.
  ///   - platformVersion: The platform version to build for.
  ///   - hotReloadingEnabled: Controls whether the hot reloading environment variables
  ///     are added to the build command or not.
  ///   - isUsingXcodeBuild: Controls whether this invocation is built using xcodebuild
  ///     or if not, falls back to build with swift (the default).
  /// - Returns: If an error occurs, returns a failure.
  static func build(
    product: String,
    packageDirectory: URL,
    configuration: BuildConfiguration,
    architectures: [BuildArchitecture],
    platform: Platform,
    platformVersion: String,
    outputDirectory: URL,
    hotReloadingEnabled: Bool = false,
    isUsingXcodeBuild: Bool = false
  ) -> Result<Void, SwiftPackageManagerError> {
    log.info("Starting \(configuration.rawValue) build")

    return createBuildArguments(
      product: product,
      configuration: configuration,
      architectures: architectures,
      platform: platform,
      platformVersion: platformVersion
    ).flatMap { arguments in

      let pipe = Pipe()
      let process: Process

      var xcbeautify: Process?
      let xcbeautifyCmd = Process.locate("xcbeautify")
      switch xcbeautifyCmd
      {
        case .success(let cmd):
          xcbeautify = Process.create(
            cmd,
            arguments: [
              "--disable-logging"
            ],
            directory: packageDirectory,
            runSilentlyWhenNotVerbose: false
          )
        case .failure(let error):
          #if os(macOS)
            let helpMsg = "brew install xcbeautify"
          #else
            let helpMsg = "mint install cpisciotta/xcbeautify"
          #endif
          log.warning("""
          xcbeautify was not found, for pretty build output please intall it with:\n
          \(helpMsg)
          """)
      }

      if isUsingXcodeBuild {
        let destinationsData = Process.create(
          "xcodebuild",
          arguments: [
            "-showdestinations",
            "-scheme", product
          ],
          directory: packageDirectory,
          runSilentlyWhenNotVerbose: false
        )
        .getOutputData()
        .flatMapError { error -> Result<Data, SimulatorManagerError> in
          return .failure(.failedToDecodeJSON(error))
        }

        // simple hardcoding of build destinations
        // for easy testing and debugging during
        // development.
        let buildingForMacOS = 1
        let buildingForXrOS = 8
        let buildFor = buildingForXrOS

        let decoder = JSONDecoder()
        guard 
          let data = destinationsData.success,
          let output = String(data: data, encoding: .utf8)
        else {
          let debugOutput = String(data: destinationsData.success ?? .init(), encoding: .utf8)
          let debug = String(debugOutput?.split(separator: "{")[buildFor] ?? "{}")
          return .failure(.failedToParseTargetInfo(json: debug, nil))
        }

        let json = output.split(separator: "{")[buildFor]
        var jsonData = String(("{" + json).split(separator: "}").joined(separator: "},").trimmingCharacters(in: .whitespacesAndNewlines).dropLast())
        jsonData = jsonData.replacingOccurrences(of: "name:My Mac", with: "\"name\":\"My Mac\"")
        jsonData = jsonData.replacingOccurrences(of: "name:Any DriverKit Host", with: "\"name\":\"Any DriverKit Host\"")
        jsonData = jsonData.replacingOccurrences(of: "name:Any \"visionOS Simulator\" Device", with: "\"name\":\"Any visionOS Simulator Device\"")
        jsonData = jsonData.replacingOccurrences(of: "name:Any visionOS Simulator Device", with: "\"name\":\"Any visionOS Simulator Device\"")
        jsonData = jsonData.replacingOccurrences(of: "name:visionOS Simulator", with: "\"name\":\"visionOS Simulator\"")
        jsonData = jsonData.replacingOccurrences(of: "platform:visionOS Simulator", with: "\"platform\":\"visionOS Simulator\"")
        jsonData = jsonData.replacingOccurrences(of: "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-xrsimulator:placeholder", with: "\"dvtdevice-DVTiOSDeviceSimulatorPlaceholder-xrsimulator:placeholder\"")
        jsonData = jsonData.replacingOccurrences(of: "arch:", with: "\"arch\":")
        jsonData = jsonData.replacingOccurrences(of: "id:", with: "\"id\":")
        jsonData = jsonData.replacingOccurrences(of: "variant:", with: "\"variant\":")
        // because we are supporting a very old swift version with swift bundler,
        // we cannot use more than one character in .split(seperator:), therefore
        // keep splitting at the ':' between { prop : value }
        let keyValueCount = String(jsonData).split(separator: ",").count
        for index in 0..<keyValueCount {
          let valueOutput = String(jsonData).split(separator: ",")[index]
          if let value = valueOutput.split(separator: ":").last {
            // values may contain ':' within them too, ensure we get the entire
            // value without chopping it up, the valuePrefixCount is calculated
            // as ((total number of ':') - 1) for the key:value seperator.
            var valuePrefixes = ""
            let valuePrefixCount = valueOutput.split(separator: ":").count - 1
            if valuePrefixCount > 1 {
              for prefixIndex in 1..<valuePrefixCount {
                valuePrefixes += valueOutput.split(separator: ":")[prefixIndex] + "@"
              }
            }

            if value.contains("My") || value.contains("Any") || value.contains("Simulator") {
              continue
            }

            // insert a '|' between { prop | value } delimitted by a '#' to use as a
            // 'progress cursor' of sorts as we progress forward through each iteration
            // of: { prop : value, } -> { 'prop' | 'value'# }
            jsonData = jsonData.replacingOccurrences(of: "\(valuePrefixes)\(value)", with: "\"\(valuePrefixes)\(value)\"")
          }
        }
        var destinationsJson = XcodeDestinations.CodingKeys.allCases.map({
          if !$0.rawValue.contains("name") {
            jsonData = jsonData.replacingOccurrences(of: "\($0.rawValue):", with: "\"\($0.rawValue)\":")
          }
          return jsonData
        })
        .joined(separator: ",")
        // cleanup our '|' {key:value} progress cursor. 
        .replacingOccurrences(of: "|", with: ":")
        // cleanup our '@' {key:value:value} progress cursor. 
        .replacingOccurrences(of: "@", with: ":")
        .split(separator: "#")
        .joined(separator: ",")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .dropLast()

        let destinations: [XcodeDestinations]
        do {
          guard let destData = ("[" + String(destinationsJson) + "}]").data(using: .utf8) else {
            return .failure(.failedToParseTargetInfo(json: String("[" + String(destinationsJson) + "}]"), nil))
          }
          destinations = try decoder.decode([XcodeDestinations].self, from: destData)
        } catch {
          return .failure(.failedToParseTargetInfo(json: String("[" + String(destinationsJson) + "}]"), error))
        }

        var destination: XcodeDestinations? = nil
        for dest in destinations.filter({ $0.platform?.contains(platform.name.replacingOccurrences(of: "Simulator", with: " Simulator")) ?? false }) {
          // if dest contains an OS property.
          //if let os = dest.OS {
          //  destination = dest
          //}
          destination = dest
          break
        }

        guard let buildDest = destination else {
          return .failure(.failedToRunSwiftBuild(
            command: "xcodebuild Could not retrieve a valid build destination.",
            .nonZeroExitStatus(-1)
          ))
        }

        process = Process.create(
          "xcodebuild",
          arguments: [
            "-scheme", product,
            "-destination", "platform=\(String(buildDest.platform ?? platform.name))\(",OS=\(String(platform == .visionOSSimulator ? "2.0" : buildDest.OS ?? platformVersion))"),name=\(platform == .visionOSSimulator ? "Apple Vision Pro" : buildDest.name)",
            "-configuration", configuration.rawValue.capitalized,
            "-usePackageSupportBuiltinSCM",
            "-derivedDataPath", "\(outputDirectory.path)/.derivedData",
            "SYMROOT=\(outputDirectory.path)"
          ],
          directory: packageDirectory,
          runSilentlyWhenNotVerbose: false
        )
      } else {
        process = Process.create(
          "swift",
          arguments: arguments,
          directory: packageDirectory,
          runSilentlyWhenNotVerbose: false
        )
      }

      if hotReloadingEnabled {
        process.addEnvironmentVariables([
          "SWIFT_BUNDLER_HOT_RELOADING": "1"
        ])
      }

      // pipe xcodebuild output to xcbeautify.
      if let xcbeautify = xcbeautify {
        process.standardOutput = pipe
        xcbeautify.standardInput = pipe
      }

      do {
        try xcbeautify?.run()
      } catch {
        log.warning("xcbeautify error: \(error)")
      }

      return process.runAndWait().mapError { error in
        return .failedToRunSwiftBuild(
          command: "\(isUsingXcodeBuild ? "xcodebuild" : "swift") \(arguments.joined(separator: " "))",
          error
        )
      }
    }
  }

  /// Builds the specified executable product of a Swift package as a dynamic library.
  /// Used in hot reloading, should not be relied upon for producing production builds.
  /// - Parameters:
  ///   - product: The product to build.
  ///   - packageDirectory: The root directory of the package containing the product.
  ///   - configuration: The build configuration to use.
  ///   - architectures: The set of architectures to build for.
  ///   - platform: The platform to build for.
  ///   - platformVersion: The platform version to build for.
  ///   - hotReloadingEnabled: Controls whether the hot reloading environment variables
  ///     are added to the build command or not.
  ///   - isUsingXcodeBuild: Controls whether this invocation is built using xcodebuild
  ///     or if not, falls back to build with swift (the default).
  /// - Returns: If an error occurs, returns a failure.
  static func buildExecutableAsDylib(
    product: String,
    packageDirectory: URL,
    configuration: BuildConfiguration,
    architectures: [BuildArchitecture],
    platform: Platform,
    platformVersion: String,
    outputDirectory: URL,
    hotReloadingEnabled: Bool = false,
    isUsingXcodeBuild: Bool = false
  ) -> Result<URL, SwiftPackageManagerError> {
    #if os(macOS)
      // TODO: Package up 'build options' into a struct so that it can be passed around
      //   more easily
      let productsDirectory: URL
      switch SwiftPackageManager.getProductsDirectory(
        in: packageDirectory,
        configuration: configuration,
        architectures: architectures,
        platform: platform,
        platformVersion: platformVersion
      ) {
        case let .success(value):
          productsDirectory = value
        case let .failure(error):
          return .failure(error)
      }
      let dylibFile = productsDirectory.appendingPathComponent("lib\(product).dylib")

      return build(
        product: product,
        packageDirectory: packageDirectory,
        configuration: configuration,
        architectures: architectures,
        platform: platform,
        platformVersion: platformVersion,
        outputDirectory: outputDirectory,
        hotReloadingEnabled: hotReloadingEnabled,
        isUsingXcodeBuild: isUsingXcodeBuild
      ).flatMap { _ in
        let buildPlanFile = packageDirectory.appendingPathComponent(".build/\(configuration).yaml")
        let buildPlanString: String
        do {
          buildPlanString = try String(contentsOf: buildPlanFile)
        } catch {
          return .failure(.failedToReadBuildPlan(path: buildPlanFile, error))
        }

        let buildPlan: BuildPlan
        do {
          buildPlan = try YAMLDecoder().decode(BuildPlan.self, from: buildPlanString)
        } catch {
          return .failure(.failedToDecodeBuildPlan(error))
        }

        let commandName = "C.\(product)-\(configuration).exe"
        guard
          let linkCommand = buildPlan.commands[commandName],
          linkCommand.tool == "shell",
          let commandExecutable = linkCommand.arguments?.first,
          let arguments = linkCommand.arguments?.dropFirst()
        else {
          return .failure(
            .failedToComputeLinkingCommand(
              details: "Couldn't find valid command for \(commandName)"
            )
          )
        }

        var modifiedArguments = Array(arguments)
        guard
          let index = modifiedArguments.firstIndex(of: "-o"),
          index < modifiedArguments.count - 1
        else {
          return .failure(
            .failedToComputeLinkingCommand(details: "Couldn't find '-o' argument to replace")
          )
        }

        modifiedArguments.remove(at: index)
        modifiedArguments.remove(at: index)
        modifiedArguments.append(contentsOf: [
          "-o",
          dylibFile.path,
          "-Xcc",
          "-dynamiclib",
        ])

        let process = Process.create(
          commandExecutable,
          arguments: modifiedArguments,
          directory: packageDirectory,
          runSilentlyWhenNotVerbose: false
        )

        return process.runAndWait()
          .map { _ in dylibFile }
          .mapError { error in
            // TODO: Make a more robust way of converting commands to strings for display (keeping
            //   correctness in mind in case users want to copy-paste commands from errors).
            return .failedToRunLinkingCommand(
              command: ([commandExecutable]
                + modifiedArguments.map { argument in
                  if argument.contains(" ") {
                    return "\"\(argument)\""
                  } else {
                    return argument
                  }
                }).joined(separator: " "),
              error
            )
          }
      }
    #else
      fatalError("buildExecutableAsDylib not implemented for current platform")
      #warning("buildExecutableAsDylib not implemented for current platform")
    #endif
  }

  /// Creates the arguments for the Swift build command.
  /// - Parameters:
  ///   - product: The product to build.
  ///   - configuration: The build configuration to use.
  ///   - architectures: The architectures to build for.
  ///   - platform: The platform to build for.
  ///   - platformVersion: The platform version to target.
  /// - Returns: The build arguments, or a failure if an error occurs.
  static func createBuildArguments(
    product: String?,
    configuration: BuildConfiguration,
    architectures: [BuildArchitecture],
    platform: Platform,
    platformVersion: String
  ) -> Result<[String], SwiftPackageManagerError> {
    let platformArguments: [String]
    switch platform {
      case .iOS, .visionOS, .tvOS:
        let sdkPath: String
        switch getLatestSDKPath(for: platform) {
          case .success(let path):
            sdkPath = path
          case .failure(let error):
            return .failure(error)
        }

        let targetTriple: String
        switch platform {
          case .iOS:
            targetTriple = "arm64-apple-ios\(platformVersion)"
          case .visionOS:
            targetTriple = "arm64-apple-xros\(platformVersion)"
          case .tvOS:
            targetTriple = "arm64-apple-tvos\(platformVersion)"
          default:
            fatalError("Unreachable (supposedly)")
        }
        platformArguments =
          [
            "-sdk", sdkPath,
            "-target", targetTriple,
          ].flatMap { ["-Xswiftc", $0] }
          + [
            "--target=\(targetTriple)",
            "-isysroot", sdkPath,
          ].flatMap { ["-Xcc", $0] }
      case .iOSSimulator, .visionOSSimulator, .tvOSSimulator:
        let sdkPath: String
        switch getLatestSDKPath(for: platform) {
          case .success(let path):
            sdkPath = path
          case .failure(let error):
            return .failure(error)
        }

        // TODO: Make target triple generation generic
        let architecture = BuildArchitecture.current.rawValue
        let targetTriple: String
        switch platform {
          case .iOSSimulator:
            targetTriple = "\(architecture)-apple-ios\(platformVersion)-simulator"
          case .visionOSSimulator:
            targetTriple = "\(architecture)-apple-xros\(platformVersion)-simulator"
          case .tvOSSimulator:
            targetTriple = "\(architecture)-apple-tvos\(platformVersion)-simulator"
          default:
            fatalError("Unreachable (supposedly)")
        }
        platformArguments =
          [
            "-sdk", sdkPath,
            "-target", targetTriple,
          ].flatMap { ["-Xswiftc", $0] }
          + [
            "--target=\(targetTriple)",
            "-isysroot", sdkPath,
          ].flatMap { ["-Xcc", $0] }
      case .macOS, .linux:
        platformArguments = []
    }

    let architectureArguments = architectures.flatMap { architecture in
      ["--arch", architecture.argument(for: platform)]
    }

    let productArguments: [String]
    if let product = product {
      productArguments = ["--product", product]
    } else {
      productArguments = []
    }

    let arguments =
      [
        "build",
        "-c", configuration.rawValue,
      ] + productArguments + architectureArguments + platformArguments

    return .success(arguments)
  }

  /// Gets the path to the latest SDK for a given platform.
  /// - Parameter platform: The platform to get the SDK path for.
  /// - Returns: The SDK's path, or a failure if an error occurs.
  static func getLatestSDKPath(for platform: Platform) -> Result<String, SwiftPackageManagerError> {
    return Process.create(
      "/usr/bin/xcrun",
      arguments: [
        "--sdk", platform.sdkName,
        "--show-sdk-path",
      ]
    ).getOutput().map { output in
      return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }.mapError { error in
      return .failedToGetLatestSDKPath(platform, error)
    }
  }

  /// Gets the version of the current Swift installation.
  /// - Returns: The swift version, or a failure if an error occurs.
  static func getSwiftVersion() -> Result<Version, SwiftPackageManagerError> {
    let process = Process.create(
      "swift",
      arguments: ["--version"])

    return process.getOutput()
      .mapError { error in
        .failedToGetSwiftVersion(error)
      }
      .flatMap { output in
        // The first two examples are for release versions of Swift (the first on macOS, the second on Linux).
        // The next two examples are for snapshot versions of Swift (the first on macOS, the second on Linux).
        // Sample: "swift-driver version: 1.45.2 Apple Swift version 5.6 (swiftlang-5.6.0.323.62 clang-1316.0.20.8)"
        //     OR: "swift-driver version: 1.45.2 Swift version 5.6 (swiftlang-5.6.0.323.62 clang-1316.0.20.8)"
        //     OR: "Apple Swift version 5.9-dev (LLVM 464b04eb9b157e3, Swift 7203d52cb1e074d)"
        //     OR: "Swift version 5.9-dev (LLVM 464b04eb9b157e3, Swift 7203d52cb1e074d)"
        let parser = OneOf {
          Parse {
            "swift-driver version"
            Prefix { $0 != "(" }
            "(swiftlang-"
            Parse({ Version(major: $0, minor: $1, patch: $2) }) {
              Int.parser(radix: 10)
              "."
              Int.parser(radix: 10)
              "."
              Int.parser(radix: 10)
            }
            Rest<Substring>()
          }.map { (_: Substring, version: Version, _: Substring) in
            version
          }

          Parse {
            Optionally {
              "Apple "
            }
            "Swift version "
            Parse({ Version(major: $0, minor: $1, patch: 0) }) {
              Int.parser(radix: 10)
              "."
              Int.parser(radix: 10)
            }
            Rest<Substring>()
          }.map { (_: Void?, version: Version, _: Substring) in
            version
          }
        }

        do {
          let version = try parser.parse(output)
          return .success(version)
        } catch {
          return .failure(.invalidSwiftVersionOutput(output, error))
        }
      }
  }

  /// Gets the default products directory for the specified package and configuration.
  /// - Parameters:
  ///   - packageDirectory: The package's root directory.
  ///   - configuration: The current build configuration.
  ///   - architectures: The architectures that the build was for.
  ///   - platform: The platform that was built for.
  ///   - platformVersion: The platform version that was built for.
  /// - Returns: The default products directory. If `swift build --show-bin-path ... # extra args`
  ///   fails, a failure is returned.
  static func getProductsDirectory(
    in packageDirectory: URL,
    configuration: BuildConfiguration,
    architectures: [BuildArchitecture],
    platform: Platform,
    platformVersion: String
  ) -> Result<URL, SwiftPackageManagerError> {
    return createBuildArguments(
      product: nil,
      configuration: configuration,
      architectures: architectures,
      platform: platform,
      platformVersion: platformVersion
    ).flatMap { arguments in
      let process = Process.create(
        "swift",
        arguments: arguments + ["--show-bin-path"],
        directory: packageDirectory
      )

      return process.getOutput().map { output in
        let path = output.trimmingCharacters(in: .newlines)
        return URL(fileURLWithPath: path)
      }.mapError { error in
        return .failedToGetProductsDirectory(command: "swift " + process.argumentsString, error)
      }
    }
  }

  /// Loads a root package manifest from a package's root directory.
  /// - Parameter packageDirectory: The package's root directory.
  /// - Returns: The loaded manifest, or a failure if an error occurs.
  static func loadPackageManifest(
    from packageDirectory: URL
  ) async -> Result<PackageManifest, SwiftPackageManagerError> {
    // We used to use the SwiftPackageManager library to load package manifests,
    // but that caused issues when the library version didn't match the user's
    // installed Swift version and was very fiddly to fix. It was easier to just
    // hand roll a custom solution that we can update in the future to maintain
    // backwards compatability.
    //
    // Overview of loading a manifest manually:
    // - Compile and link manifest with Swift driver
    // - Run the resulting executable with `-fileno 1` as its args
    // - Parse the JSON that the executable outputs to stdout

    let manifestPath = packageDirectory.appendingPathComponent("Package.swift").path
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let uuid = UUID().uuidString
    let temporaryExecutableFile =
      temporaryDirectory
      .appendingPathComponent("\(uuid)-PackageManifest").path

    #if os(Linux)
      let temporaryAutolinkFile =
        temporaryDirectory
        .appendingPathComponent("\(uuid)-PackageManifest.autolink").path
    #endif

    let targetInfo: SwiftTargetInfo
    switch self.getTargetInfo() {
      case .success(let info):
        targetInfo = info
      case .failure(let error):
        return .failure(error)
    }

    let manifestAPIDirectory = targetInfo.paths.runtimeResourcePath
      .appendingPathComponent("pm/ManifestAPI")

    var librariesPaths: [String] = []
    librariesPaths += targetInfo.paths.runtimeLibraryPaths.map(\.path)
    librariesPaths += [manifestAPIDirectory.path]

    var additionalSwiftArguments: [String] = []
    #if os(macOS)
      switch self.getLatestSDKPath(for: .macOS) {
        case .success(let path):
          librariesPaths += [path + "/usr/lib/swift"]
          additionalSwiftArguments += ["-sdk", path]
        case .failure(let error):
          return .failure(error)
      }
    #endif

    let toolsVersionProcess = Process.create(
      "swift",
      arguments: ["package", "tools-version"],
      directory: packageDirectory
    )
    let toolsVersion: String
    let swiftMajorVersion: String
    switch toolsVersionProcess.getOutput() {
      case .success(let output):
        toolsVersion = output.trimmingCharacters(in: .whitespacesAndNewlines)
        swiftMajorVersion = String(toolsVersion.first!)
      case .failure(let error):
        return .failure(.failedToParsePackageManifestToolsVersion(error))
    }

    // Compile to object file
    let swiftArguments =
      [
        manifestPath,
        "-I", manifestAPIDirectory.path,
        "-Xlinker", "-rpath", "-Xlinker", manifestAPIDirectory.path,
        "-lPackageDescription",
        "-swift-version", swiftMajorVersion, "-package-description-version", toolsVersion,
        "-disable-implicit-concurrency-module-import",
        "-disable-implicit-string-processing-module-import",
        "-o", temporaryExecutableFile,
      ]
      + librariesPaths.flatMap { ["-L", $0] }
      + additionalSwiftArguments

    let swiftProcess = Process.create("swiftc", arguments: swiftArguments)
    if case let .failure(error) = swiftProcess.runAndWait() {
      return .failure(.failedToCompilePackageManifest(error))
    }

    // Execute compiled manifest
    let process = Process.create(temporaryExecutableFile, arguments: ["-fileno", "1"])
    let json: String
    switch process.getOutput() {
      case .success(let output):
        json = output
      case .failure(let error):
        return .failure(.failedToExecutePackageManifest(error))
    }

    // Parse manifest output
    guard let jsonData = json.data(using: .utf8) else {
      return .failure(.failedToParsePackageManifestOutput(json: json, nil))
    }

    do {
      return .success(
        try JSONDecoder().decode(PackageManifest.self, from: jsonData)
      )
    } catch {
      return .failure(.failedToParsePackageManifestOutput(json: json, error))
    }
  }

  static func getTargetInfo() -> Result<SwiftTargetInfo, SwiftPackageManagerError> {
    // TODO: This could be a nice easy one to unit test
    let process = Process.create(
      "swift",
      arguments: ["-print-target-info"]
    )

    return process.getOutput().mapError { error in
      return .failedToGetTargetInfo(command: "swift " + process.argumentsString, error)
    }.flatMap { output in
      guard let data = output.data(using: .utf8) else {
        return .failure(.failedToParseTargetInfo(json: output, nil))
      }
      do {
        return .success(
          try JSONDecoder().decode(SwiftTargetInfo.self, from: data))
      } catch {
        return .failure(.failedToParseTargetInfo(json: output, error))
      }
    }
  }
}
