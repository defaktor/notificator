import SwiftUI
import AVFoundation
import UIKit

struct QRScanner:UIViewControllerRepresentable {
    let onScan:(String) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context:Context) -> ScannerController {
        let controller=ScannerController(); controller.onScan=onScan; controller.onClose={ dismiss() }; return controller
    }
    func updateUIViewController(_ controller:ScannerController,context:Context) {}
}
final class ScannerController:UIViewController,AVCaptureMetadataOutputObjectsDelegate {
    var onScan:((String) -> Void)?,onClose:(() -> Void)?
    private let capture=AVCaptureSession()
    private let captureQueue=DispatchQueue(label:"dev.anbridge.camera")
    private var preview:AVCaptureVideoPreviewLayer?
    private var scanned=false
    private let label=UILabel()
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        label.text="Наведите камеру на QR в ANBridge на Android"; label.textColor = .white; label.numberOfLines=0; label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(label)
        let close=UIButton(type:.system); close.setTitle("Закрыть",for:.normal); close.tintColor = .white; close.addTarget(self,action:#selector(closeScanner),for:.touchUpInside); close.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(close)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:24),label.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-24),label.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-36),close.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:12),close.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-24)])
        guard let camera=AVCaptureDevice.default(for:.video),let input=try? AVCaptureDeviceInput(device:camera),capture.canAddInput(input) else { label.text="Камера недоступна. Проверьте разрешение в настройках iOS."; return }
        capture.addInput(input)
        let output=AVCaptureMetadataOutput()
        guard capture.canAddOutput(output) else { label.text="Сканирование QR недоступно"; return }
        capture.addOutput(output); output.setMetadataObjectsDelegate(self,queue:.main); output.metadataObjectTypes=[.qr]
        let preview=AVCaptureVideoPreviewLayer(session:capture); preview.videoGravity = .resizeAspectFill; view.layer.insertSublayer(preview,at:0); self.preview=preview
        captureQueue.async { self.capture.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame=view.bounds }
    override func viewDidDisappear(_ animated:Bool) { super.viewDidDisappear(animated); captureQueue.async { self.capture.stopRunning() } }
    @objc private func closeScanner() { onClose?() }
    func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput metadataObjects:[AVMetadataObject],from connection:AVCaptureConnection) {
        guard !scanned,let value=(metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        scanned=true; UIImpactFeedbackGenerator(style:.light).impactOccurred(); captureQueue.async { self.capture.stopRunning() }; onScan?(value)
    }
}
