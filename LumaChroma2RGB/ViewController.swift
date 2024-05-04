//
//  ViewController.swift
//  LumaChroma2RGB_Metal
//
//  Created by mark lim pak mun on 03/05/2024.
//  Copyright © 2024 Incremental Innovations. All rights reserved.
//

import Cocoa
import MetalKit

class ViewController: NSViewController {

    var metalView: MTKView {
        return self.view as! MTKView
    }

    var metalRenderer: MetalRenderer!

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let defaultDevice = MTLCreateSystemDefaultDevice()
        else {
            fatalError("No Metal-capable GPU")
        }

        metalView.colorPixelFormat = .bgra8Unorm
        metalView.device = defaultDevice
        metalRenderer = MetalRenderer(view: metalView, device: defaultDevice)
        metalView.delegate = metalRenderer

        metalRenderer.mtkView(metalView,
                              drawableSizeWillChange: metalView.drawableSize)
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }


}

