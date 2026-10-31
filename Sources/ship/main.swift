import Foundation
import ShipCore

Interrupt.install()
exit(Ship.run(arguments: Array(CommandLine.arguments.dropFirst())))
