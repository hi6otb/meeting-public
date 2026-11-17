import AVFoundation
import ScreenCaptureKit

enum RecordingPermissions {
    static func ensureMicrophone(status: AVAuthorizationStatus, request: () async -> Bool) async throws {
        switch status {
        case .authorized:
            return
        case .notDetermined:
            guard await request() else { throw microphoneDenied }
        case .denied:
            throw microphoneDenied
        case .restricted:
            throw AppFailure("このMacの管理設定でマイクの利用が制限されています。")
        @unknown default:
            throw AppFailure("マイクの権限状態を確認できませんでした。アプリを終了して開き直してください。")
        }
    }
    private static var microphoneDenied: AppFailure {
        AppFailure("マイクの利用が許可されていません。システム設定 → プライバシーとセキュリティ → マイクでInterviewを許可してください。すでにオンの場合は、Interviewを終了して開き直してください。")
    }
    static func explainCaptureError(_ error: Error) -> Error {
        let value = error as NSError
        guard value.domain == SCStreamErrorDomain, value.code == SCStreamError.Code.userDeclined.rawValue else { return error }
        return AppFailure("macOSが画面とシステムオーディオ録音を拒否しました。許可がオンでも、旧版の署名に結び付いた登録が残っている場合があります。オン／オフで直らない場合は、Interviewの画面収録権限の登録をリセットして、新しく許可する必要があります。権限を変更した後はアプリを終了して開き直してください。")
    }
}
