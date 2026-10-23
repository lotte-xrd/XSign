# XSign

Assinador e instalador de `.ipa` para iOS, no estilo do ESign. SwiftUI, iOS 16+.

Este repositório é o **código-fonte** do app. O `.ipa` em si precisa ser compilado no
macOS com o Xcode — iOS não compila no Windows/Linux. Veja "Como compilar" abaixo.

> Estado: **scaffold funcional**. A interface, o design system, os modelos, a
> localização e a camada de serviços estão escritos. Os motores nativos
> (assinatura via zsign e servidor HTTPS local de instalação) estão como
> protocolos com implementação de referência a integrar no macOS — veja
> `Core/Services/SigningService.swift` e `Core/Services/InstallService.swift`.
> O scaffold não foi compilado aqui (foi escrito no Windows); espere pequenos
> ajustes ao abrir no Xcode pela primeira vez.

## Como compilar

### Opção A — XcodeGen (recomendada)

1. Em um Mac com Xcode 15+, instale o XcodeGen:
   ```bash
   brew install xcodegen
   ```
2. Na pasta do projeto:
   ```bash
   xcodegen generate
   open XSign.xcodeproj
   ```
3. Em *Signing & Capabilities*, selecione sua equipe (Apple Developer).
4. Build & Run num iPhone (iOS 16+).

### Opção B — Sem XcodeGen

1. Xcode → *File ▸ New ▸ Project ▸ iOS App* (SwiftUI, nome `XSign`).
2. Apague os arquivos gerados e arraste as pastas `App/`, `DesignSystem/`,
   `Core/`, `Features/` e `Resources/` para dentro do target.
3. Em *Build Settings*, aponte o Info.plist para `Resources/Info.plist` e
   adicione os idiomas (en, pt-BR, es) em *Project ▸ Localizations*.

## Gerar o `.ipa`

Depois de rodar no device com o seu certificado:

```bash
xcodebuild -scheme XSign -configuration Release -archivePath build/XSign.xcarchive archive
xcodebuild -exportArchive -archivePath build/XSign.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/ipa
```

Como o XSign é um assinador, ele próprio é distribuído por sideload (AltStore/
SideStore, TrollStore, ou assinado com um certificado). Não entra na App Store.

## Compilar na nuvem (GitHub Actions) — sem precisar de um Mac

Em `.github/workflows/` há dois fluxos. Para usar: crie um repositório no GitHub,
suba este projeto (`git init && git add . && git commit -m "XSign" && git push`) e
abra a aba **Actions**.

### `build.yml` — .ipa não assinado (recomendado)

Roda sozinho a cada push na `main` (ou manualmente em *Actions ▸ Build IPA
(unsigned) ▸ Run workflow*). Não precisa de nenhum segredo. No fim, baixe o
artefato **XSign-unsigned-ipa**. Esse `.ipa` ainda não está assinado — assine com
o seu certificado pelo próprio XSign, pelo AltStore/SideStore ou pelo Feather. É
assim que os apps desse gênero são distribuídos.

### `build-signed.yml` — .ipa assinado (opcional)

Só roda manualmente. Gera o `.ipa` já assinado com o **seu** certificado,
importado dos Secrets do repositório. Adicione em *Settings ▸ Secrets and
variables ▸ Actions*:

| Secret | Conteúdo |
|--------|----------|
| `BUILD_CERTIFICATE_BASE64` | `base64 -i certificado.p12` |
| `P12_PASSWORD` | senha do `.p12` |
| `BUILD_PROVISION_BASE64` | `base64 -i Perfil.mobileprovision` |
| `KEYCHAIN_PASSWORD` | uma senha temporária qualquer |
| `APPLE_TEAM_ID` | o ID da sua equipe (ex.: `7HQ2K4M9XA`) |

Ajuste o `method` em `ExportOptions.plist` (`development` ou `ad-hoc`) conforme o
seu perfil. O certificado fica só nos Secrets do seu repositório.

> Como o scaffold não foi compilado aqui, a primeira execução pode apontar erros
> de compilação no log do Actions — normais num primeiro build. Corrija o que ele
> indicar e rode de novo.

## Motores nativos a integrar (no macOS)

| Peça | O que é | Onde entra |
|------|---------|-----------|
| **zsign** | Assinatura de código (C++/OpenSSL) | `Vendor/zsign/` + bridge em `Core/Services/SigningService.swift` |
| **ZIPFoundation** | Extrair/empacotar o `.ipa` | SwiftPM, já declarado em `project.yml` |
| **Servidor HTTPS local** | Instalação via `itms-services` | `Core/Services/InstallService.swift` (Swifter/FlyingFox) |

Todos são projetos de código aberto maduros. Confira as licenças antes de
embutir — o zsign e várias referências do gênero usam licenças copyleft.

## Estrutura

```
App/            Entrada e as 5 abas
DesignSystem/   Tokens (cores/espaços/raios) e componentes reutilizáveis
Core/
  Models/       Source, AppItem, Certificate, SignOptions…
  Services/     Fontes, downloads, certificados, assinatura, instalação
  Localization/ LocalizationManager (troca de idioma em tempo real)
  Store/        Persistência simples (JSON em Documents)
Features/       Telas por aba (Store, Downloads, Apps, Files, Settings)
Resources/      Info.plist, Assets.xcassets, *.lproj
```

## Blueprint

O desenho de telas, identidade visual e decisões de produto estão no blueprint
visual que acompanha o projeto.
