enum AppServicesBootstrap {
    static func start() {
        let diagnosticLog = DiagnosticLog.shared
        let timedBoot = diagnosticLog.startTimed("Daemon services boot")
        DesktopModel.shared.start()
        StateHistory.shared.start()
        BundleModules.startServices()
        // After the bundle, so its history is in place before the first scan.
        ScreenText.shared.install(OcrModel.shared)
        OcrModel.shared.start()
        TmuxModel.shared.start()
        ProcessModel.shared.start()
        LatticesVoiceRuntime.start()
        LatticesApi.setup()
        DaemonServer.shared.start()
        diagnosticLog.finish(timedBoot)
    }

    static func stop() {
        LatticesVoiceRuntime.stop()
        WorkspaceAssistantSession.shared.shutdown()
        DaemonServer.shared.stop()
    }
}
