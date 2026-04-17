import * as PIXI from 'pixi.js'

var type = "WebGL";
if (!PIXI.utils.isWebGLSupported()) {
    type = "canvas";
}

var players = {}
var ratio = 0

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
    sprite.position.set(100 * ratio, 100 * ratio)
    // // sprite.width = 20
    // // sprite.height = 20
    // // sprite.zIndex = 100

    // scene.addChild(sprite)
    // sprite.position.set(0)
    bg.texture.baseTexture.on('loaded', function () {
        console.log(bg.width, bg.height)
        ratio = bg.width / 3000.0
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
    const clist = e.detail.characters
    // console.log("自定义事件：", clist)
    let cids = clist.map(function (ele, idx, data) {
        return ele.cid
    })
    // console.log(cids)
    clist.forEach(character => {

        if (players[character.cid] == null) {
            let sprite = PIXI.Sprite.from('/images/arrow_64.png')
            scene.addChild(sprite)

            
        // // console.log(players[character.cid].rotation)
        // let angle = getRotation(character.location.x - sprite.position.x, character.location.y - sprite.position.y)
        // // console.log(character.location.x * ratio - sprite.position.x, character.location.y * ratio - sprite.position.y)
        // // console.log(players[character.cid].position)
        // // players[character.cid].angle = angle
        // // sprite.rotation = radian
        // sprite.angle = angle

            sprite.position.set(character.location.x * ratio, character.location.y * ratio)
            sprite.pivot.set(32, 32)
            sprite.scale.set(0.5)
            players[character.cid] = sprite
        } else {
            // console.log(players[character.cid].rotation)
            const dx = character.location.x * ratio - players[character.cid].position.x
            const dy = character.location.y * ratio - players[character.cid].position.y
            if (dx != 0 || dy != 0) {
                let angle = getAngle(dx, dy)
                console.log(angle)
                players[character.cid].angle = angle + 180
            }

            players[character.cid].position.set(character.location.x * ratio, character.location.y * ratio)
        }
    });


    for (const key in players) {
        if (!cids.includes(parseInt(key))) {
            // console.log("player leave")
            scene.removeChild(players[key])
            delete players[key]
        }
    }
})

function getAngle(x, y) {
    var angle = Math.atan2(y, x);   //弧度
    // you need to devide by PI, and MULTIPLY by 180:
    var degrees = 180 * angle / Math.PI;  //角度

    return degrees
}