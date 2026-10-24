# Notify

Self-hosted notifications with a web client and partial ntfy compatibility.

## Installation

```sh
git clone https://github.com/P4suta/notify.git
cd notify
docker compose -f compose.sqlite.yml up --build notify
```

## Usage

```sh
# Open the setup URL printed at startup within 15 minutes.
# Create administrator admin with a password of 12 to 1024 characters.
# Keep anonymous access set to deny.
# In another terminal, enter that password when curl prompts.
curl --user admin --data 'deployment complete' http://localhost:8080/alerts
```

## Documentation

[Read the documentation](docs/README.md).

## License

The existing license terms are in [LICENSE](LICENSE) and [NOTICE](NOTICE).
