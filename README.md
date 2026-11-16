# ANBridge для iPhone

Нативный приёмник уведомлений Android для iPhone. Работает по Bluetooth Low Energy без сервера и интернета. Для обмена требуется совместимое Android-приложение ANBridge.

В проект входят SwiftUI-интерфейс, сканирование QR, Core Bluetooth, защищённая привязка Noise XX, локальная история, защита от повторов и локальные уведомления.

## Открыть и установить

1. Клонируйте репозиторий и откройте `ios/ANBridge.xcodeproj` в полном Xcode.
2. Дождитесь загрузки Swift Package Dependencies. Версии закреплены в `Package.resolved`.
3. В Xcode → Settings → Apple Accounts добавьте свой Apple ID.
4. В target ANBridge → Signing & Capabilities выберите свою Team и оставьте Automatically manage signing. При необходимости задайте уникальный Bundle Identifier.
5. Подключите iPhone, включите Developer Mode и выберите телефон в качестве Run Destination.
6. Нажмите Product → Run. После установки свяжите устройства через QR Android-приложения.

Минимальная версия iOS — 17. Для личной установки можно использовать бесплатную Personal Team. В опубликованном проекте Team намеренно не задана. Приватные ключи и provisioning profiles не включены.

## Проверки

```sh
swift test --package-path ios --jobs 4
swift run --package-path ios ANBridgeCoreCheck
```

Проверка нативной сборки без подписи:

```sh
xcodebuild -project ios/ANBridge.xcodeproj -scheme ANBridge -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Нативная сборка проверена с Xcode 26.6 и iOS SDK 26.5. Подпись и установка выполняются учётной записью владельца. Фоновую доставку и восстановление связи необходимо проверить на физических устройствах: их поведение зависит от iOS и настроек телефона.

Криптографические зависимости: swift-noise с закреплённым commit, Apple swift-crypto 4.0.0 и swift-asn1 1.7.4. Они загружаются Swift Package Manager. История защищена Data Protection, ключи пары хранятся в Keychain.
