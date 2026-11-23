import AppKit

/// A non-activating HUD. It can show a title plus a live transcript preview
/// while the user is speaking.
final class HUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, detail: String? = nil, sticky: Bool = false) {
        ensurePanel()
        let detail = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let height: CGFloat = detail.isEmpty ? 60 : 118
        panel?.setContentSize(NSSize(width: 520, height: height))
        label?.attributedStringValue = attributed(text: text, detail: detail)
        position()
        panel?.orderFrontRegardless()

        hideWork?.cancel()
        hideWork = nil
        guard !sticky else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func attributed(text: String, detail: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleFont = detail.isEmpty
            ? NSFont.systemFont(ofSize: 15, weight: .medium)
            : NSFont.systemFont(ofSize: 13, weight: .regular)
        let titleColor = detail.isEmpty ? NSColor.labelColor : NSColor.secondaryLabelColor
        result.append(NSAttributedString(
            string: text,
            attributes: [.font: titleFont, .foregroundColor: titleColor]
        ))
        if !detail.isEmpty {
            result.append(NSAttributedString(string: "\n"))
            result.append(NSAttributedString(
                string: detail,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ]
            ))
        }
        return result
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])

        panel.contentView = effect
        self.panel = panel
        self.label = label
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 90
        ))
    }
}
