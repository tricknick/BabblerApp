Babbler — установка / обновление

РЕКОМЕНДУЕТСЯ (и для первой установки, и для обновления поверх старой):
  1. Правый клик по "Install Babbler.command" → Открыть → Открыть.
     (macOS 15+: если заблокировано — Системные настройки →
      Конфиденциальность и безопасность → "Всё равно открыть".)
  2. Скрипт сам: закроет запущенный Babbler, заменит
     /Applications/Babbler.app, снимет карантин, уберёт лишние копии
     из LaunchServices и сбросит старые разрешения (у каждой сборки
     новая подпись — старые разрешения к ней не подходят).
  3. Включите Babbler в Конфиденциальность и безопасность →
     Универсальный доступ (Accessibility) и Мониторинг ввода
     (Input Monitoring). Перезапустите Babbler.

Вручную (без скрипта):
  - Закройте Babbler, перетащите Babbler.app в Applications (заменить).
  - xattr -dr com.apple.quarantine /Applications/Babbler.app
  - tccutil reset Accessibility eugene.Babbler
    tccutil reset ListenEvent eugene.Babbler
  - Запустите /Applications/Babbler.app и выдайте оба разрешения.
  - Не запускайте Babbler прямо с этого диска — права выдаются
    копии в /Applications.

Опционально: включите Launch at Login в настройках Babbler.

---
English: right-click "Install Babbler.command" → Open. It quits Babbler,
replaces /Applications/Babbler.app, clears quarantine and stale
permission grants. Then enable Babbler in Accessibility and Input
Monitoring and relaunch it.
