# test_eDM

GitHub에 eDM 폴더가 올라오면 폴더 안의 HTML을 기반으로 Outlook template(`.oft`)을 생성하는 CI/CD 구성입니다.

## 동작 방식

1. `*.html`, `*.htm`, 또는 이미지 파일이 push되면 `.github/workflows/build-oft.yml`이 실행됩니다.
2. 워크플로가 변경된 HTML 파일의 부모 폴더를 찾고, 이미지가 바뀐 경우에는 가장 가까운 HTML 포함 폴더를 찾습니다.
3. GitHub-hosted `windows-latest` runner에서 `.NET + MsgKit` 변환기를 실행합니다.
4. `tools/HtmlToOft`가 HTML을 읽고 같은 폴더에 `파일명.oft`를 생성합니다.
5. 생성 결과와 메타데이터는 `파일명_oft_build.json`에 기록됩니다.
6. `.oft`와 `*_oft_build.json`은 GitHub Actions artifact로 업로드되고, 기본값으로 현재 브랜치에도 커밋됩니다.

## 별도 설정이 필요한 것

Outlook이 설치된 Windows self-hosted runner는 필요하지 않습니다. 기본 workflow는 GitHub가 제공하는 `windows-latest` runner에서 실행됩니다.

다만 repo 설정에서 Actions가 결과 파일을 다시 push할 수 있어야 합니다.

- `Settings > Actions > General > Workflow permissions`
- `Read and write permissions` 선택
- 브랜치 보호 규칙이 bot push를 막으면 artifact만 받거나 PR 방식으로 바꿔야 합니다.

## 폴더 업로드 규칙

폴더 안에 서버 발송용 HTML과 이미지를 넣어 push하면 됩니다.

```text
campaign_001/
  campaign_001.html
  images/
    img_01.png
    cta_button.png
```

상대 이미지 경로(`images/img_01.png`)는 OFT 안에서 `cid:` inline attachment로 변환됩니다. 이미 `https://...` 절대 URL인 이미지는 그대로 둡니다.

같은 폴더에 `campaign_001.html`과 `campaign_001_local.html`이 같이 있으면 `_local.html`은 건너뛰고 서버용 HTML을 우선 처리합니다.

## 수동 실행

GitHub Actions에서 `Build Outlook templates` 워크플로를 수동 실행하고 `folder`에 처리할 폴더명을 입력할 수 있습니다.

로컬에 .NET 8 SDK가 있으면 직접 실행할 수도 있습니다.

```powershell
dotnet run --project tools/HtmlToOft/HtmlToOft.csproj -- `
  --folder campaign_001 `
  --repository-root .
```

## 변환 방식 참고

이 저장소의 기본 방식은 Outlook desktop 자동화가 아니라 `MsgKit`으로 Outlook compatible compound file을 직접 생성하는 방식입니다.

- GitHub `oft` 토픽에는 `html-to-oft`, `html2oft-converter` 같은 오픈소스 변환기들이 있습니다.
- `html2oft-converter`는 HTML+이미지를 EML로 만들고, .NET `MsgKit`으로 OFT를 생성하는 구조를 사용합니다.
- `MsgKit`은 Outlook 호환 메시지를 생성하는 100% managed .NET 라이브러리입니다.

주의할 점도 있습니다. Outlook desktop의 `Save As > Outlook Template (*.oft)`로 직접 저장한 파일과 완전히 동일한 경로는 아니므로, 최종 운영 전에는 실제 Windows Outlook에서 열림/이미지/링크를 샘플 검증하는 것이 좋습니다.

## 선택 사항: Outlook COM 방식

`scripts/build-oft.ps1`은 Outlook desktop COM을 사용하는 보조 스크립트입니다. Outlook이 설치된 Windows 환경에서만 쓸 수 있고, GitHub-hosted runner에서는 동작하지 않습니다.

Microsoft 공식 Outlook `MailItem.SaveAs`의 `olTemplate` 형식 값은 `2`입니다. 참고: [MailItem.SaveAs](https://learn.microsoft.com/en-us/office/vba/api/outlook.mailitem.saveas), [OlSaveAsType](https://learn.microsoft.com/en-us/office/vba/api/outlook.olsaveastype)
