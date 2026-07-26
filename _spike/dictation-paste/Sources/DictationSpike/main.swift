import AppKit

let app = NSApplication.shared
let controller = SpikeController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
