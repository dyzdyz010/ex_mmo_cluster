import { Application, Container, Point, Sprite } from "pixi.js"

const SCENE_WIDTH = 3000

let app = null
let scene = null
let background = null
const players = new Map()
let ratio = 1
let dragTarget = null

async function ensureScene() {
    const mount = document.querySelector("#scene-canvas")

    if (!mount) {
        return
    }

    if (!app) {
        app = new Application()
        await app.init({
            antialias: true,
            background: 0x0f172a,
            resizeTo: mount
        })

        scene = new Container()
        scene.eventMode = "static"
        scene.on("pointerdown", onDragStart)

        app.stage.eventMode = "static"
        app.stage.hitArea = app.screen
        app.stage.on("pointerup", onDragEnd)
        app.stage.on("pointerupoutside", onDragEnd)
        app.stage.addChild(scene)
    }

    if (!mount.contains(app.canvas)) {
        mount.replaceChildren(app.canvas)
    }

    await ensureBackground()
}

async function ensureBackground() {
    if (background) {
        return
    }

    background = Sprite.from("/images/scene.png")
    background.anchor.set(0)
    background.position.set(0)
    scene.addChild(background)

    const updateRatio = () => {
        if (background.width > 0) {
            ratio = background.width / SCENE_WIDTH
        }
    }

    updateRatio()

    if (background.texture?.baseTexture && !background.texture.baseTexture.valid) {
        background.texture.baseTexture.once("loaded", updateRatio)
    }
}

function onDragStart(event) {
    dragTarget = scene
    dragTarget.alpha = 0.92
    dragTarget.offCoord = event.global.clone()
    app.stage.on("pointermove", onDragMove)
}

function onDragMove(event) {
    if (!dragTarget) {
        return
    }

    const movement = new Point(
        event.global.x - dragTarget.offCoord.x,
        event.global.y - dragTarget.offCoord.y
    )

    dragTarget.position.x += movement.x
    dragTarget.position.y += movement.y
    dragTarget.offCoord = event.global.clone()
}

function onDragEnd() {
    if (!dragTarget) {
        return
    }

    app.stage.off("pointermove", onDragMove)
    dragTarget.alpha = 1
    dragTarget = null
}

window.addEventListener("DOMContentLoaded", () => {
    void ensureScene()
})

window.addEventListener("phx:page-loading-stop", () => {
    void ensureScene()
})

window.addEventListener("phx:data", async (event) => {
    await ensureScene()

    const characterList = event.detail.characters || []
    const activeIds = new Set(characterList.map((character) => character.cid))

    characterList.forEach((character) => {
        const x = character.location.x * ratio
        const y = character.location.y * ratio

        if (!players.has(character.cid)) {
            const sprite = Sprite.from("/images/arrow_64.png")
            sprite.position.set(x, y)
            sprite.pivot.set(32, 32)
            sprite.scale.set(0.5)
            scene.addChild(sprite)
            players.set(character.cid, sprite)
            return
        }

        const sprite = players.get(character.cid)
        const dx = x - sprite.position.x
        const dy = y - sprite.position.y

        if (dx !== 0 || dy !== 0) {
            sprite.angle = getAngle(dx, dy) + 180
        }

        sprite.position.set(x, y)
    })

    for (const [cid, sprite] of players.entries()) {
        if (activeIds.has(cid)) {
            continue
        }

        scene.removeChild(sprite)
        players.delete(cid)
    }
})

function getAngle(x, y) {
    return (180 * Math.atan2(y, x)) / Math.PI
}
