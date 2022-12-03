import * as PIXI from 'pixi.js'

var type = "WebGL";
if (!PIXI.utils.isWebGLSupported()) {
    type = "canvas";
}

const app = new PIXI.Application({ width: window.innerWidth, height: window.innerHeight })
const scene = new PIXI.Container()

window.addEventListener('phx:page-loading-stop', (info) => {
    makeScene()
    // document.querySelector("#pixi").appendChild(app.view)
    document.body.appendChild(app.view)
    // app.stage.width = app.view.width
    // app.stage.height = app.view.height
    // app.stage.
    app.renderer.backgroundColor = 0xbcbcbc;
    // app.renderer.autoResize = false
    // app.renderer.resize(app.view.width, app.view.height)
    // app.renderer.view.width = app.view.width
    // app.renderer.view.height = app.view.height
    // container.width = 5000
    // container.height = 5000

    window.addEventListener('resize', resize);
    resize()
})

function makeScene() {
    app.stage.interactive = true
    app.stage.hitArea = app.screen
    app.stage.on('pointerup', onDragEnd)
    app.stage.on('pointerupoutside', onDragEnd)

    scene.interactive = true
    scene.on('pointerdown', onDragStart, scene)
    app.stage.addChild(scene)

    // container.position.set(50)

    const bg = PIXI.Sprite.from('/images/scene.png')
    bg.anchor.set(0)
    bg.position.set(0)
    // bg.scale.set(0.001)
    scene.addChild(bg)

    let sprite = PIXI.Sprite.from('/images/arrow_64.png')
    sprite.scale.set(0.5)
    // sprite.width = 20
    // sprite.height = 20
    // sprite.zIndex = 100

    scene.addChild(sprite)
    sprite.position.set(0)
    bg.texture.baseTexture.on('loaded', function() {
        console.log(bg.height)
    })
}

function resize() {

    // Get the p
    const parent = app.view.parentNode.parentNode;
    // console.log(parent.clientHeight)
    // Resize the renderer
    app.renderer.resize(window.innerWidth, window.innerHeight)
}

let dragTarget = null

function onDragStart(event) {
    // console.log(event.screen)
    // console.log(this)
    this.alpha = 0.7
    dragTarget = this
    // dragTarget.offsetX = dragTarget.parent.toLocal(event.global, dragTarget).x
    // dragTarget.offsetY = dragTarget.parent.toLocal(event.global, dragTarget).y

    // dragTarget.offCoord = dragTarget.toLocal(event.global, null)
    // dragTarget.offCoord = new PIXI.Point()
    dragTarget.offCoord = event.global.clone()
    // dragTarget.offCoord.x = event.global.x
    // dragTarget.offCoord.y = event.global.y

    app.stage.on('pointermove', onDragMove)
    // dragTarget.pivot.set(event.screen - dragTarget.position)
}

function onDragMove(event) {
    if (dragTarget) {
        // console.log(dragTarget.offCoord)
        let movement = new PIXI.Point()
        movement.x = event.global.x - dragTarget.offCoord.x
        movement.y = event.global.y - dragTarget.offCoord.y
        let newPos = dragTarget.toLocal(event.global, null)
        // dragTarget.position.x = newPos.x - dragTarget.offCoord.x
        // dragTarget.position.y = newPos.y - dragTarget.offCoord.y
        // console.log(movement)
        dragTarget.position.x += movement.x
        dragTarget.position.y += movement.y

        // dragTarget.parent.toLocal(event.global, null, dragTarget.position)
        dragTarget.offCoord = event.global.clone()
    }
}

function onDragEnd() {
    if (dragTarget) {
        app.stage.off('pointermove', onDragMove)
        dragTarget.alpha = 1
        dragTarget = null
        // console.log(this.children[0])
    }
}

window.addEventListener(`phx:data`, (e) => {
    console.log("自定义事件：", e)
})