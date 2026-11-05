Установка RemnaWave Node + SelfSNI

Что делает скрипт
- Устанавливает Docker, Docker Compose и Remnawave Node с network_mode: host.
- Запрашивает домен, порт ноды и SECRET_KEY из панели.
- Устанавливает acme.sh через GitHub и выпускает ECC-сертификат Let's Encrypt.
- Размещает заглушку-страницу CloudNode в Nginx на 127.0.0.1:8443.
- Настраивает автоматическое продление сертификата с перезагрузкой конфигурации Nginx.
- Применяет BBR при поддержке ядром, увеличивает очереди TCP и лимиты открытых файлов.
- Ограничивает размер Docker-логов и создаёт резервные копии изменяемых конфигураций.

Требования: В профиле указать:
inbounds:
{
  "target": "127.0.0.1:8443",
  "xver": 0,
  "serverNames": ["node.example.com"]
}

Установка: bash <(curl -Ls https://raw.githubusercontent.com/radmir42/remna-selfsni/main/install.sh)
