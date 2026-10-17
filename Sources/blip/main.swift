import BlipCore
import Foundation

#if canImport(AppKit)
let display: CardDisplay = HUDDisplay()
#else
let display: CardDisplay = UnavailableDisplay()
#endif

exit(BlipCLI(display: display).run(Array(CommandLine.arguments.dropFirst())))
