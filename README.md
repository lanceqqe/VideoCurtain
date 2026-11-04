# Video Curtain

Расширение Safari для macOS: когда Safari открыт в полноэкранном режиме, видео разворачивается на весь экран без создания отдельного рабочего стола. В обычном окне Safari работает как обычно и создаёт отдельный рабочий стол.

## Как это устроено

- `extension/` — расширение: перехватывает запрос полного экрана и растягивает плеер на всю страницу.
- `VideoCurtain/` — проект Xcode: приложение скрывает панель Safari на время просмотра и закрывает чёрным всё вокруг страницы.

## Сборка и установка

Нужен Xcode. В `VideoCurtain/VideoCurtain.xcodeproj/project.xcproj` укажите свой `DEVELOPMENT_TEAM`, затем выполните:

```bash
cd VideoCurtain
xcodebuild -project VideoCurtain.xcodeproj -scheme VideoCurtain -configuration Release -derivedDataPath build -allowProvisioningUpdates build
ditto build/Build/Products/Release/VideoCurtain.app /Applications/VideoCurtain.app
rm -rf build
open /Applications/VideoCurtain.app
```

После установки:

1. Разрешите VideoCurtain в «Системные настройки → Конфиденциальность и безопасность → Универсальный доступ».
2. Включите Video Curtain в «Safari → Настройки → Расширения» и разрешите ему доступ к нужным сайтам. Если расширения нет в списке, включите «Разрешить неподписанные расширения» в разделе «Для разработчиков».

## Ограничения

- Режим Safari определяется по размеру окна. Обычное окно, развёрнутое почти на весь экран при скрытом Dock, может быть принято за полноэкранное.
- На кнопку встроенного плеера Safari расширение, скорее всего, не влияет.
