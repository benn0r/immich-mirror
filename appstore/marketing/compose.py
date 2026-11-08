"""Composes the App Store header and search-results assets.

Backgrounds in source/ were generated with OpenAI gpt-image-2; source/icon.png is exported from
AppIcon.icon with Icon Composer's ictool. Text and the phone screenshot are drawn here so they stay
crisp and show the real app (screenshots from `npm run screenshots`).
Run with a Python that has Pillow:  python compose.py [languages…]
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
FONT = "/System/Library/Fonts/SFNS.ttf"
ICON = HERE / "source/icon.png"
SCREENSHOTS = ROOT / "screenshots/appstore"

# language: (header title, header line, search title, search line)
TEXT = {
    "en": (
        'Your photos. Your server.',
        'iCloud Photos mirrored to your own server: new photos, edits, deletions and albums.',
        'Mirror iCloud Photos\nto your own server.',
        'Deletions and albums stay in sync.',
    ),
    "de": (
        'Deine Fotos. Dein Server.',
        'Deine iCloud-Fotos gespiegelt auf deinen eigenen Server: neue Fotos, Bearbeitungen, Löschungen und Alben.',
        'iCloud-Fotos auf deinen\neigenen Server spiegeln.',
        'Löschungen und Alben bleiben synchron.',
    ),
    "fr": (
        'Vos photos. Votre serveur.',
        'Vos Photos iCloud reproduites sur votre propre serveur : nouvelles photos, retouches, suppressions et albums.',
        'Reproduisez Photos iCloud\nsur votre propre serveur.',
        'Suppressions et albums restent synchronisés.',
    ),
    "it": (
        'Le tue foto. Il tuo server.',
        'Le tue foto di iCloud replicate sul tuo server: nuove foto, modifiche, eliminazioni e album.',
        'Replica le foto di iCloud\nsul tuo server.',
        'Eliminazioni e album restano sincronizzati.',
    ),
    "es": (
        'Tus fotos. Tu servidor.',
        'Tus fotos de iCloud replicadas en tu propio servidor: fotos nuevas, ediciones, eliminaciones y álbumes.',
        'Replica tus fotos de iCloud\nen tu propio servidor.',
        'Eliminaciones y álbumes siempre sincronizados.',
    ),
    "nl": (
        "Jouw foto's. Jouw server.",
        "Je iCloud-foto's gespiegeld naar je eigen server: nieuwe foto's, bewerkingen, verwijderingen en albums.",
        "Spiegel iCloud-foto's\nnaar je eigen server.",
        'Verwijderingen en albums blijven gesynchroniseerd.',
    ),
    "pt-PT": (
        'As suas fotografias. O seu servidor.',
        'As suas fotografias do iCloud espelhadas no seu servidor: novas fotografias, edições, eliminações e álbuns.',
        'Espelhe as fotografias do iCloud\nno seu servidor.',
        'Eliminações e álbuns ficam sincronizados.',
    ),
    "pt-BR": (
        'Suas fotos. Seu servidor.',
        'Suas fotos do iCloud espelhadas no seu próprio servidor: fotos novas, edições, exclusões e álbuns.',
        'Espelhe suas fotos do iCloud\nno seu próprio servidor.',
        'Exclusões e álbuns ficam sincronizados.',
    ),
    "sv": (
        'Dina bilder. Din server.',
        'Dina iCloud-bilder speglade till din egen server: nya bilder, redigeringar, raderingar och album.',
        'Spegla iCloud-bilder\ntill din egen server.',
        'Raderingar och album hålls synkade.',
    ),
    "da": (
        'Dine billeder. Din server.',
        'Dine iCloud-billeder spejlet til din egen server: nye billeder, redigeringer, sletninger og albummer.',
        'Spejl iCloud-billeder\ntil din egen server.',
        'Sletninger og albummer holdes synkroniseret.',
    ),
    "nb": (
        'Dine bilder. Din server.',
        'iCloud-bildene dine speilet til din egen server: nye bilder, redigeringer, slettinger og album.',
        'Speil iCloud-bilder\ntil din egen server.',
        'Slettinger og album holdes synkronisert.',
    ),
    "fi": (
        'Sinun kuvasi. Sinun palvelimesi.',
        'iCloud-kuvasi peilattuna omalle palvelimellesi: uudet kuvat, muokkaukset, poistot ja albumit.',
        'Peilaa iCloud-kuvat\nomalle palvelimellesi.',
        'Poistot ja albumit pysyvät synkronoituina.',
    ),
    "ja": (
        'あなたの写真を、あなたのサーバに。',
        'iCloud写真を自分のサーバにミラー。新しい写真、編集、削除、アルバムまで。',
        'iCloud写真を\n自分のサーバにミラー。',
        '削除もアルバムも同期されたまま。',
    ),
    "pl": (
        'Twoje zdjęcia. Twój serwer.',
        'Twoje Zdjęcia iCloud odzwierciedlone na własnym serwerze: nowe zdjęcia, edycje, usunięcia i albumy.',
        'Odzwierciedlaj Zdjęcia iCloud\nna własnym serwerze.',
        'Usunięcia i albumy pozostają zsynchronizowane.',
    ),
    "zh-Hans": (
        '你的照片，你的服务器。',
        '将 iCloud 照片镜像到你自己的服务器：新照片、编辑、删除和相簿。',
        '将 iCloud 照片\n镜像到你自己的服务器。',
        '删除和相簿都会保持同步。',
    ),
    "zh-Hant": (
        '你的照片，你的伺服器。',
        '將 iCloud 照片鏡像到你自己的伺服器：新照片、編輯、刪除和相簿。',
        '將 iCloud 照片\n鏡像到你自己的伺服器。',
        '刪除和相簿都會保持同步。',
    ),
    "ko": (
        '내 사진, 내 서버.',
        'iCloud 사진을 내 서버에 그대로 미러링: 새 사진, 편집, 삭제, 앨범까지.',
        'iCloud 사진을\n내 서버에 미러링하세요.',
        '삭제와 앨범도 그대로 동기화됩니다.',
    ),
    "uk": (
        'Ваші фото. Ваш сервер.',
        'Ваші Фото iCloud віддзеркалені на власний сервер: нові фото, редагування, видалення й альбоми.',
        'Віддзеркалюйте Фото iCloud\nна власний сервер.',
        'Видалення й альбоми залишаються синхронізованими.',
    ),
    "cs": (
        'Vaše fotky. Váš server.',
        'Vaše Fotky na iCloudu zrcadlené na vlastní server: nové fotky, úpravy, mazání a alba.',
        'Zrcadlete Fotky na iCloudu\nna vlastní server.',
        'Mazání i alba zůstávají synchronizované.',
    ),
    "tr": (
        'Senin fotoğrafların. Senin sunucun.',
        'iCloud Fotoğrafların kendi sunucuna yansıtılır: yeni fotoğraflar, düzenlemeler, silmeler ve albümler.',
        'iCloud Fotoğraflarını\nkendi sunucuna yansıt.',
        'Silmeler ve albümler senkronize kalır.',
    ),
}
SERIF = "/System/Library/Fonts/NewYork.ttf"
INK = (20, 32, 43, 255)
MUTED = (74, 88, 102, 255)

language = "en"


# New York and SF have no CJK glyphs: (serif title, body) faces as (file, collection index) per language.
SYSTEM = "/System/Library/Fonts/"
CJK = {
    "ja": ((SYSTEM + "ヒラギノ明朝 ProN.ttc", 2), (SYSTEM + "ヒラギノ角ゴシック W3.ttc", 0)),
    "zh-Hans": ((SYSTEM + "Supplemental/Songti.ttc", 1), (SYSTEM + "STHeiti Light.ttc", 1)),
    "zh-Hant": ((SYSTEM + "Supplemental/Songti.ttc", 2), (SYSTEM + "STHeiti Light.ttc", 0)),
    "ko": ((SYSTEM + "AppleSDGothicNeo.ttc", 14), (SYSTEM + "AppleSDGothicNeo.ttc", 0)),
}


def font(size: int, weight: str = "Regular", serif: bool = False) -> ImageFont.FreeTypeFont:
    if language in CJK:
        path, index = CJK[language][0 if serif else 1]
        return ImageFont.truetype(path, size, index=index)
    f = ImageFont.truetype(SERIF if serif else FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def fitted(content: str, size: int, max_width: int, weight: str = "Regular", serif: bool = False):
    """The largest font up to `size` whose widest line fits in `max_width`."""
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    while size > 10:
        f = font(size, weight, serif)
        if probe.multiline_textbbox((0, 0), content, font=f)[2] <= max_width:
            return f
        size -= 2
    return font(size, weight, serif)


def centered(canvas: Image.Image, y: int, content: str, f, fill, spacing: int = 0) -> int:
    """Draws centered (multi-line) text with its top at `y`; returns the bottom."""
    draw = ImageDraw.Draw(canvas)
    box = draw.multiline_textbbox((0, 0), content, font=f, spacing=spacing, align="center")
    x = (canvas.width - (box[2] - box[0])) // 2 - box[0]
    draw.multiline_text((x, y - box[1]), content, font=f, fill=fill, spacing=spacing, align="center")
    return y + box[3] - box[1]


def rounded(image: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *image.size), radius, fill=255)
    out = image.convert("RGBA")
    out.putalpha(mask)
    return out


def soft_shadow(canvas: Image.Image, box, radius: int, blur: int, alpha: int, dy: int = 0) -> None:
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(layer).rounded_rectangle((x0, y0 + dy, x1, y1 + dy), radius, fill=(30, 50, 70, alpha))
    canvas.alpha_composite(layer.filter(ImageFilter.GaussianBlur(blur)))


def app_icon(size: int) -> Image.Image:
    """The exported icon already has its rounded shape and transparent corners."""
    return Image.open(ICON).convert("RGBA").resize((size, size), Image.LANCZOS)


def phone(screenshot: Image.Image, width: int) -> Image.Image:
    """A light titanium-style frame around a real screenshot."""
    shot = screenshot.resize((width, round(screenshot.height * width / screenshot.width)), Image.LANCZOS)
    bezel = round(width * 0.035)
    radius = round(width * 0.17)
    body = Image.new("RGBA", (shot.width + 2 * bezel, shot.height + 2 * bezel), (0, 0, 0, 0))
    d = ImageDraw.Draw(body)
    d.rounded_rectangle((0, 0, *body.size), radius, fill=(214, 220, 228, 255))
    d.rounded_rectangle((4, 4, body.width - 5, body.height - 5), radius - 4, fill=(16, 18, 22, 255))
    inner = bezel - round(width * 0.012)
    body.alpha_composite(rounded(shot, radius - bezel), (bezel, bezel))
    return body


def header(language: str, out: Path) -> None:
    title, line, _, _ = TEXT[language]
    canvas = Image.open(HERE / "source/header-bg.png").convert("RGBA").crop((0, 0, 3840, 1646))
    icon_size = 190
    x = (canvas.width - icon_size) // 2
    soft_shadow(canvas, (x + 12, 150, x + icon_size - 12, 150 + icon_size), 44, 30, 70, dy=18)
    canvas.alpha_composite(app_icon(icon_size), (x, 150))
    bottom = centered(canvas, 420, title, fitted(title, 176, 2900, "Bold", serif=True), INK)
    centered(canvas, bottom + 84, line, fitted(line, 64, 2600), MUTED)
    canvas.convert("RGB").save(out / "header-3840x1646.png", optimize=True)


def search_results(language: str, out: Path) -> None:
    _, _, title, line = TEXT[language]
    shot = SCREENSHOTS / ("home.png" if language == "en" else f"{language}/home.png")
    canvas = Image.open(HERE / "source/search-bg.png").convert("RGBA")
    icon_size = 112
    x = (canvas.width - icon_size) // 2
    soft_shadow(canvas, (x + 8, 56, x + icon_size - 8, 56 + icon_size), 26, 18, 60, dy=10)
    canvas.alpha_composite(app_icon(icon_size), (x, 56))
    bottom = centered(canvas, 204, title, fitted(title, 80, 1100, "Bold", serif=True), INK, spacing=6)
    bottom = centered(canvas, bottom + 40, line, fitted(line, 38, 1000), MUTED)
    device = phone(Image.open(shot), 520)
    dx = (canvas.width - device.width) // 2
    dy = bottom + 56
    soft_shadow(canvas, (dx + 20, dy, dx + device.width - 20, dy + device.height), 90, 40, 90, dy=24)
    canvas.alpha_composite(device, (dx, dy))
    canvas.convert("RGB").save(out / "search-results-1920x1280.png", optimize=True)


if __name__ == "__main__":
    for language in sys.argv[1:] or TEXT:
        globals()["language"] = language
        out = HERE if language == "en" else HERE / language
        out.mkdir(exist_ok=True)
        header(language, out)
        search_results(language, out)
        print(out)
