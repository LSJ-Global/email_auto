import {defineSecret} from "firebase-functions/params";
import {setGlobalOptions} from "firebase-functions/v2";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {createHash} from "node:crypto";

const GITHUB_TOKEN = defineSecret("GITHUB_TOKEN");

const GITHUB_OWNER = "LSJ-Global";
const GITHUB_REPOSITORY = "edm_auto_site";
const TARGET_BRANCH = "main";
const WORKFLOW_FILE = "generate-edm.yml";
const GITHUB_API_VERSION = "2026-03-10";
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_BASE64_LENGTH = Math.ceil(MAX_IMAGE_BYTES / 3) * 4;
const SUPPORTED_EXTENSIONS = new Set(["png", "jpg", "jpeg", "webp"]);
const RESERVED_IMAGE_NAMES = new Set([".git", ".github", "scripts", "tools"]);

setGlobalOptions({
  region: "asia-northeast3",
  maxInstances: 5,
  timeoutSeconds: 60,
  memory: "256MiB",
});

interface SubmitEdmJobData {
  fileName?: unknown;
  contentBase64?: unknown;
  landingUrls?: unknown;
}

interface GetEdmJobStatusData {
  targetFolder?: unknown;
}

interface DeleteEdmJobData {
  targetFolder?: unknown;
  imagePath?: unknown;
}

interface ValidatedSubmission {
  fileName: string;
  contentBase64: string;
  contentBytes: Buffer;
  landingUrls: string[];
}

interface GitHubCommitResponse {
  content?: {
    path?: string;
    sha?: string;
  };
  commit?: {
    sha?: string;
    html_url?: string;
  };
}

interface WorkflowDispatchResponse {
  workflow_run_id?: number;
  html_url?: string;
}

interface GitHubContentItem {
  name?: string;
  path?: string;
  type?: string;
  size?: number;
  download_url?: string | null;
  html_url?: string | null;
}

interface GitHubFolderLookup {
  folderName: string;
  response: Response;
}

interface GitHubRefResponse {
  object?: {sha?: string};
}

interface GitHubCommitDetail {
  tree?: {sha?: string};
}

interface GitHubTreeItem {
  path?: string;
  type?: string;
}

interface GitHubTreeResponse {
  sha?: string;
  tree?: GitHubTreeItem[];
  truncated?: boolean;
}

interface GitHubCreatedCommit {
  sha?: string;
}

class GitHubApiError extends Error {
  constructor(
    readonly status: number,
    readonly responseBody: string,
  ) {
    super(`GitHub API request failed with status ${status}`);
  }
}

export const submitEdmJob = onCall(
  {
    secrets: [GITHUB_TOKEN],
    enforceAppCheck: false,
  },
  async (request) => {
    requireVerifiedUser(request.auth?.token);
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }
    const submission = validateSubmission(request.data as SubmitEdmJobData);
    const originalImageName = imageNameFromFileName(submission.fileName);
    const githubFileName = accountScopedFileName(submission.fileName, uid);
    const githubSubmission = {...submission, fileName: githubFileName};
    const token = GITHUB_TOKEN.value();

    await ensureGitHubPathIsAvailable(githubFileName, token);

    let upload: GitHubCommitResponse;
    try {
      upload = await uploadImage(githubSubmission, token);
    } catch (error) {
      throw mapGitHubError(error, "원본 이미지를 GitHub에 업로드하지 못했습니다.");
    }

    let workflow: WorkflowDispatchResponse;
    try {
      workflow = await dispatchWorkflow(githubSubmission, token);
    } catch (error) {
      logger.error("Workflow dispatch failed after image upload", {
        fileName: githubFileName,
        commitSha: upload.commit?.sha,
        error,
      });
      throw new HttpsError(
        "internal",
        "이미지는 업로드됐지만 생성 워크플로 호출에 실패했습니다.",
        {
          imagePath: githubFileName,
          commitSha: upload.commit?.sha ?? null,
          recoverable: true,
        },
      );
    }

    logger.info("eDM job submitted", {
      uid,
      originalFileName: submission.fileName,
      githubFileName,
      commitSha: upload.commit?.sha,
      workflowRunId: workflow.workflow_run_id,
    });

    return {
      imagePath: githubFileName,
      displayName: originalImageName,
      commitSha: upload.commit?.sha ?? null,
      commitUrl: upload.commit?.html_url ?? null,
      workflowRunId: workflow.workflow_run_id ?? null,
      workflowRunUrl: workflow.html_url ?? null,
      targetFolder: imageNameFromFileName(githubFileName),
      status: "queued",
    };
  },
);

export const getEdmJobStatus = onCall(
  {
    secrets: [GITHUB_TOKEN],
    enforceAppCheck: false,
  },
  async (request) => {
    requireVerifiedUser(request.auth?.token);
    const targetFolder = validateTargetFolder(
      (request.data as GetEdmJobStatusData)?.targetFolder,
    );

    let lookup: GitHubFolderLookup;
    try {
      lookup = await findGitHubResultFolder(
        targetFolder,
        GITHUB_TOKEN.value(),
      );
    } catch (error) {
      throw mapGitHubError(error, "GitHub 결과 파일을 조회하지 못했습니다.");
    }

    const resolvedFolder = lookup.folderName;
    const folderUrl =
      `https://github.com/${GITHUB_OWNER}/${GITHUB_REPOSITORY}` +
      `/tree/${TARGET_BRANCH}/${encodeURIComponent(resolvedFolder)}`;
    if (lookup.response.status === 404) {
      return {
        targetFolder: resolvedFolder,
        status: "processing",
        folderUrl,
        files: [],
      };
    }

    const contents = await lookup.response.json() as GitHubContentItem[];
    if (!Array.isArray(contents)) {
      throw new HttpsError("internal", "GitHub 결과 폴더 형식이 올바르지 않습니다.");
    }

    const supportedResultExtensions = new Set(["html", "eml", "oft", "zip"]);
    const files = contents
      .flatMap((item) => {
        if (item.type !== "file" || typeof item.name !== "string") {
          return [];
        }
        if (item.name.toLowerCase().endsWith("_local.html")) {
          return [];
        }
        const extension = item.name.split(".").pop()?.toLowerCase() ?? "";
        return [{
          name: item.name,
          type: extension,
          size: item.size ?? 0,
          downloadUrl: item.download_url ?? item.html_url ?? null,
          htmlUrl: item.html_url ?? null,
        }];
      })
      .filter((item) =>
        supportedResultExtensions.has(item.type) &&
        typeof item.downloadUrl === "string",
      )
      .sort((a, b) => a.name.localeCompare(b.name));

    const availableExtensions = new Set(files.map((file) => file.type));
    const complete = ["html", "eml", "oft"].every((extension) =>
      availableExtensions.has(extension),
    );

    return {
      targetFolder: resolvedFolder,
      status: complete ? "complete" : "processing",
      folderUrl,
      files,
    };
  },
);

export const deleteEdmJob = onCall(
  {
    secrets: [GITHUB_TOKEN],
    enforceAppCheck: false,
  },
  async (request) => {
    requireVerifiedUser(request.auth?.token);
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }

    const requestedFolder = validateTargetFolder(
      (request.data as DeleteEdmJobData)?.targetFolder,
    );
    const imagePath = validateFileName(
      (request.data as DeleteEdmJobData)?.imagePath,
      220,
    );
    if (!isAccountScopedJob(imagePath, requestedFolder, uid)) {
      throw new HttpsError(
        "permission-denied",
        "이 계정에서 생성한 GitHub 작업만 삭제할 수 있습니다.",
      );
    }

    let resultFolder = requestedFolder;
    try {
      const lookup = await findGitHubResultFolder(
        requestedFolder,
        GITHUB_TOKEN.value(),
      );
      resultFolder = lookup.folderName;
      await deleteGitHubJobFiles(
        imagePath,
        resultFolder,
        GITHUB_TOKEN.value(),
      );
    } catch (error) {
      throw mapGitHubError(error, "GitHub 작업 파일을 삭제하지 못했습니다.");
    }

    logger.info("eDM job deleted", {
      uid,
      requestedFolder,
      resultFolder,
      imagePath,
    });
    return {
      status: "deleted",
      targetFolder: requestedFolder,
      githubDeleted: true,
    };
  },
);

function requireVerifiedUser(
  token: Record<string, unknown> | undefined,
): void {
  if (!token) {
    throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
  }
  if (token.email_verified !== true) {
    throw new HttpsError(
      "permission-denied",
      "이메일 인증이 완료된 계정만 작업을 생성할 수 있습니다.",
    );
  }
}

function validateSubmission(data: SubmitEdmJobData): ValidatedSubmission {
  const fileName = validateFileName(data.fileName);
  const contentBase64 = validateBase64(data.contentBase64);
  const contentBytes = Buffer.from(contentBase64, "base64");
  if (contentBytes.length === 0 || contentBytes.length > MAX_IMAGE_BYTES) {
    throw new HttpsError(
      "invalid-argument",
      `이미지 크기는 1 byte 이상 ${MAX_IMAGE_BYTES} bytes 이하여야 합니다.`,
    );
  }

  validateImageSignature(fileName, contentBytes);
  const landingUrls = validateLandingUrls(data.landingUrls);
  return {fileName, contentBase64, contentBytes, landingUrls};
}

function validateFileName(value: unknown, maxByteLength = 180): string {
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", "파일명이 필요합니다.");
  }

  const fileName = value.normalize("NFC").trim();
  const byteLength = Buffer.byteLength(fileName, "utf8");
  if (
    !fileName ||
    fileName === "." ||
    fileName === ".." ||
    fileName.startsWith(".") ||
    fileName.includes("/") ||
    fileName.includes("\\") ||
    /[\u0000-\u001f\u007f]/u.test(fileName) ||
    byteLength > maxByteLength
  ) {
    throw new HttpsError("invalid-argument", "사용할 수 없는 파일명입니다.");
  }

  const extension = fileName.split(".").pop()?.toLowerCase() ?? "";
  if (!SUPPORTED_EXTENSIONS.has(extension)) {
    throw new HttpsError(
      "invalid-argument",
      "PNG, JPG, JPEG, WEBP 이미지만 업로드할 수 있습니다.",
    );
  }
  const imageName = imageNameFromFileName(fileName);
  if (RESERVED_IMAGE_NAMES.has(imageName.toLowerCase())) {
    throw new HttpsError(
      "invalid-argument",
      "예약된 이름은 이미지명으로 사용할 수 없습니다.",
    );
  }
  return fileName;
}

function validateTargetFolder(value: unknown): string {
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", "결과 폴더명이 필요합니다.");
  }

  const targetFolder = value.normalize("NFC").trim();
  const byteLength = Buffer.byteLength(targetFolder, "utf8");
  if (
    !targetFolder ||
    targetFolder === "." ||
    targetFolder === ".." ||
    targetFolder.startsWith(".") ||
    targetFolder.includes("/") ||
    targetFolder.includes("\\") ||
    /[\u0000-\u001f\u007f]/u.test(targetFolder) ||
    byteLength > 180 ||
    RESERVED_IMAGE_NAMES.has(targetFolder.toLowerCase())
  ) {
    throw new HttpsError("invalid-argument", "사용할 수 없는 결과 폴더명입니다.");
  }
  return targetFolder;
}

function validateBase64(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_BASE64_LENGTH ||
    value.length % 4 !== 0 ||
    !/^[A-Za-z0-9+/]*={0,2}$/u.test(value)
  ) {
    throw new HttpsError(
      "invalid-argument",
      "이미지 데이터가 올바른 base64 형식이 아닙니다.",
    );
  }
  return value;
}

function validateImageSignature(fileName: string, bytes: Buffer): void {
  const extension = fileName.split(".").pop()?.toLowerCase();
  const isPng =
    bytes.length >= 8 &&
    bytes.subarray(0, 8).equals(
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    );
  const isJpeg =
    bytes.length >= 3 &&
    bytes[0] === 0xff &&
    bytes[1] === 0xd8 &&
    bytes[2] === 0xff;
  const isWebp =
    bytes.length >= 12 &&
    bytes.subarray(0, 4).toString("ascii") === "RIFF" &&
    bytes.subarray(8, 12).toString("ascii") === "WEBP";

  const signatureMatches =
    (extension === "png" && isPng) ||
    ((extension === "jpg" || extension === "jpeg") && isJpeg) ||
    (extension === "webp" && isWebp);
  if (!signatureMatches) {
    throw new HttpsError(
      "invalid-argument",
      "파일 확장자와 실제 이미지 형식이 일치하지 않습니다.",
    );
  }
}

function validateLandingUrls(value: unknown): string[] {
  if (value === undefined || value === null) {
    return [];
  }
  if (!Array.isArray(value) || value.length > 20) {
    throw new HttpsError(
      "invalid-argument",
      "landingUrls는 최대 20개의 URL 배열이어야 합니다.",
    );
  }

  return value.map((item) => {
    if (typeof item !== "string" || item.length > 2048) {
      throw new HttpsError("invalid-argument", "유효하지 않은 URL입니다.");
    }
    const candidate = item.includes("://") ? item.trim() : `https://${item.trim()}`;
    let parsed: URL;
    try {
      parsed = new URL(candidate);
    } catch {
      throw new HttpsError("invalid-argument", "유효하지 않은 URL입니다.");
    }
    if (!["http:", "https:"].includes(parsed.protocol) || !parsed.hostname) {
      throw new HttpsError("invalid-argument", "HTTP(S) URL만 사용할 수 있습니다.");
    }
    return parsed.toString();
  });
}

async function ensureGitHubPathIsAvailable(
  fileName: string,
  token: string,
): Promise<void> {
  const response = await githubRequest(
    `/contents/${encodeURIComponent(fileName)}?ref=${TARGET_BRANCH}`,
    token,
    {method: "GET"},
    [200, 404],
  );
  if (response.status === 200) {
    throw new HttpsError(
      "already-exists",
      "GitHub에 같은 이름의 파일이 이미 존재합니다.",
    );
  }
}

async function uploadImage(
  submission: ValidatedSubmission,
  token: string,
): Promise<GitHubCommitResponse> {
  const response = await githubRequest(
    `/contents/${encodeURIComponent(submission.fileName)}`,
    token,
    {
      method: "PUT",
      body: JSON.stringify({
        message: `Upload ${submission.fileName} from Firebase`,
        content: submission.contentBase64,
        branch: TARGET_BRANCH,
      }),
    },
    [201],
  );
  return await response.json() as GitHubCommitResponse;
}

async function dispatchWorkflow(
  submission: ValidatedSubmission,
  token: string,
): Promise<WorkflowDispatchResponse> {
  const response = await githubRequest(
    `/actions/workflows/${WORKFLOW_FILE}/dispatches`,
    token,
    {
      method: "POST",
      body: JSON.stringify({
        ref: TARGET_BRANCH,
        inputs: {
          image_path: submission.fileName,
          landing_urls: submission.landingUrls.join("\n"),
        },
      }),
    },
    [200, 204],
  );
  if (response.status === 204) {
    return {};
  }
  return await response.json() as WorkflowDispatchResponse;
}

async function deleteGitHubJobFiles(
  imagePath: string,
  resultFolder: string,
  token: string,
): Promise<void> {
  const refResponse = await githubRequest(
    `/git/ref/heads/${encodeURIComponent(TARGET_BRANCH)}`,
    token,
    {method: "GET"},
    [200],
  );
  const ref = await refResponse.json() as GitHubRefResponse;
  const headSha = ref.object?.sha;
  if (!headSha) {
    throw new Error("GitHub branch head SHA is missing");
  }

  const commitResponse = await githubRequest(
    `/git/commits/${headSha}`,
    token,
    {method: "GET"},
    [200],
  );
  const commit = await commitResponse.json() as GitHubCommitDetail;
  const baseTreeSha = commit.tree?.sha;
  if (!baseTreeSha) {
    throw new Error("GitHub base tree SHA is missing");
  }

  const treeResponse = await githubRequest(
    `/git/trees/${baseTreeSha}?recursive=1`,
    token,
    {method: "GET"},
    [200],
  );
  const tree = await treeResponse.json() as GitHubTreeResponse;
  if (tree.truncated === true || !Array.isArray(tree.tree)) {
    throw new Error("GitHub repository tree is incomplete");
  }

  const resultPrefix = `${resultFolder}/`;
  const paths = tree.tree
    .filter((item) =>
      item.type === "blob" &&
      typeof item.path === "string" &&
      (item.path === imagePath || item.path.startsWith(resultPrefix)),
    )
    .map((item) => item.path as string);
  if (paths.length === 0) {
    return;
  }

  const newTreeResponse = await githubRequest(
    "/git/trees",
    token,
    {
      method: "POST",
      body: JSON.stringify({
        base_tree: baseTreeSha,
        tree: paths.map((path) => ({
          path,
          mode: "100644",
          type: "blob",
          sha: null,
        })),
      }),
    },
    [201],
  );
  const newTree = await newTreeResponse.json() as GitHubTreeResponse;
  if (!newTree.sha) {
    throw new Error("GitHub deletion tree SHA is missing");
  }

  const newCommitResponse = await githubRequest(
    "/git/commits",
    token,
    {
      method: "POST",
      body: JSON.stringify({
        message: `Delete eDM job ${resultFolder} from Firebase`,
        tree: newTree.sha,
        parents: [headSha],
      }),
    },
    [201],
  );
  const newCommit = await newCommitResponse.json() as GitHubCreatedCommit;
  if (!newCommit.sha) {
    throw new Error("GitHub deletion commit SHA is missing");
  }

  await githubRequest(
    `/git/refs/heads/${encodeURIComponent(TARGET_BRANCH)}`,
    token,
    {
      method: "PATCH",
      body: JSON.stringify({sha: newCommit.sha, force: false}),
    },
    [200],
  );
}

async function githubRequest(
  path: string,
  token: string,
  init: RequestInit,
  expectedStatuses: number[],
): Promise<Response> {
  const response = await fetch(
    `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPOSITORY}${path}`,
    {
      ...init,
      headers: {
        "Accept": "application/vnd.github+json",
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
        "User-Agent": "edm-auto-project-firebase",
      },
    },
  );
  if (!expectedStatuses.includes(response.status)) {
    throw new GitHubApiError(response.status, await response.text());
  }
  return response;
}

async function findGitHubResultFolder(
  requestedFolder: string,
  token: string,
): Promise<GitHubFolderLookup> {
  const exactResponse = await githubRequest(
    `/contents/${encodeURIComponent(requestedFolder)}?ref=${TARGET_BRANCH}`,
    token,
    {method: "GET"},
    [200, 404],
  );
  if (exactResponse.status === 200) {
    return {folderName: requestedFolder, response: exactResponse};
  }

  const rootResponse = await githubRequest(
    `/contents?ref=${TARGET_BRANCH}`,
    token,
    {method: "GET"},
    [200],
  );
  const rootContents = await rootResponse.json() as GitHubContentItem[];
  if (!Array.isArray(rootContents)) {
    return {folderName: requestedFolder, response: exactResponse};
  }

  const directories = rootContents
    .filter((item) => item.type === "dir" && typeof item.name === "string")
    .map((item) => item.name as string);
  const requestedKey = folderMatchKey(requestedFolder);
  const normalizedMatches = directories.filter(
    (name) => folderMatchKey(name) === requestedKey,
  );
  const prefixMatches = normalizedMatches.length === 0 ?
    directories.filter((name) =>
      hasFolderPrefixMatch(folderMatchKey(name), requestedKey),
    ) :
    [];
  const matches = normalizedMatches.length > 0 ?
    normalizedMatches :
    prefixMatches;

  if (matches.length !== 1) {
    logger.info("GitHub result folder not resolved", {
      requestedFolder,
      normalizedMatchCount: normalizedMatches.length,
      prefixMatchCount: prefixMatches.length,
    });
    return {folderName: requestedFolder, response: exactResponse};
  }

  const resolvedFolder = matches[0];
  logger.info("GitHub result folder resolved", {
    requestedFolder,
    resolvedFolder,
  });
  const resolvedResponse = await githubRequest(
    `/contents/${encodeURIComponent(resolvedFolder)}?ref=${TARGET_BRANCH}`,
    token,
    {method: "GET"},
    [200, 404],
  );
  return {folderName: resolvedFolder, response: resolvedResponse};
}

function folderMatchKey(value: string): string {
  return value
    .normalize("NFC")
    .trim()
    .replace(/\.(png|jpe?g|webp)$/iu, "")
    .replace(/\s+/gu, " ")
    .toLocaleLowerCase("en-US");
}

function hasFolderPrefixMatch(left: string, right: string): boolean {
  const shorter = left.length <= right.length ? left : right;
  const longer = left.length <= right.length ? right : left;
  if (!longer.startsWith(shorter) || longer.length === shorter.length) {
    return false;
  }
  return /[._\-\s]/u.test(longer.charAt(shorter.length));
}

function mapGitHubError(error: unknown, fallback: string): HttpsError {
  if (error instanceof HttpsError) {
    return error;
  }
  if (error instanceof GitHubApiError) {
    logger.error(fallback, {
      status: error.status,
      responseBody: error.responseBody,
    });
    if (error.status === 401 || error.status === 403) {
      return new HttpsError(
        "failed-precondition",
        "GitHub 인증 또는 저장소 권한을 확인해 주세요.",
      );
    }
    if (error.status === 409 || error.status === 422) {
      return new HttpsError("already-exists", fallback);
    }
  } else {
    logger.error(fallback, error);
  }
  return new HttpsError("internal", fallback);
}

function imageNameFromFileName(fileName: string): string {
  const stem = fileName.replace(/\.(png|jpe?g|webp)$/iu, "");
  const separator = stem.lastIndexOf("_");
  if (separator <= 0) {
    return stem;
  }

  const possibleName = stem.slice(0, separator);
  const possibleUrl = stem.slice(separator + 1);
  try {
    const candidate = possibleUrl.includes("://") ?
      possibleUrl :
      `https://${possibleUrl}`;
    const parsed = new URL(candidate);
    if (parsed.hostname.includes(".")) {
      return possibleName;
    }
  } catch {
    // The suffix is part of the image name rather than a URL.
  }
  return stem;
}

function accountScopedFileName(fileName: string, uid: string): string {
  const extensionSeparator = fileName.lastIndexOf(".");
  const stem = fileName.slice(0, extensionSeparator);
  const extension = fileName.slice(extensionSeparator + 1);
  const accountKey = accountKeyForUid(uid);
  return `${stem}__acct_${accountKey}.${extension}`;
}

function accountKeyForUid(uid: string): string {
  return createHash("sha256")
    .update(uid, "utf8")
    .digest("hex")
    .slice(0, 12);
}

function isAccountScopedJob(
  imagePath: string,
  targetFolder: string,
  uid: string,
): boolean {
  const marker = `__acct_${accountKeyForUid(uid)}`;
  return targetFolder.endsWith(marker) &&
    imageNameFromFileName(imagePath).endsWith(marker);
}
