"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.default = void 0;
var _nodePath = _interopRequireDefault(require("node:path"));
var _clientS = require("@aws-sdk/client-s3");
var _libStorage = require("@aws-sdk/lib-storage");
require("@aws-sdk/signature-v4-crt");
var _s3PresignedPost = require("@aws-sdk/s3-presigned-post");
var _s3RequestPresigner = require("@aws-sdk/s3-request-presigner");
var _fsExtra = _interopRequireDefault(require("fs-extra"));
var _invariant = _interopRequireDefault(require("invariant"));
var _compact = _interopRequireDefault(require("lodash/compact"));
var _tmp = _interopRequireDefault(require("tmp"));
var _env = _interopRequireDefault(require("./../../env"));
var _Logger = _interopRequireDefault(require("./../../logging/Logger"));
var _BaseStorage = _interopRequireDefault(require("./BaseStorage"));
function _interopRequireDefault(e) { return e && e.__esModule ? e : { default: e }; }
function _defineProperty(e, r, t) { return (r = _toPropertyKey(r)) in e ? Object.defineProperty(e, r, { value: t, enumerable: !0, configurable: !0, writable: !0 }) : e[r] = t, e; }
function _toPropertyKey(t) { var i = _toPrimitive(t, "string"); return "symbol" == typeof i ? i : i + ""; }
function _toPrimitive(t, r) { if ("object" != typeof t || !t) return t; var e = t[Symbol.toPrimitive]; if (void 0 !== e) { var i = e.call(t, r || "default"); if ("object" != typeof i) return i; throw new TypeError("@@toPrimitive must return a primitive value."); } return ("string" === r ? String : Number)(t); } // https://github.com/aws/aws-sdk-js-v3#functionality-requiring-aws-common-runtime-crt
class S3Storage extends _BaseStorage.default {
  constructor() {
    var _this;
    super();
    _this = this;
    _defineProperty(this, "store", async _ref => {
      let {
        body,
        contentType,
        key,
        acl
      } = _ref;
      const upload = new _libStorage.Upload({
        client: this.client,
        params: {
          ...(acl && {
            ACL: acl
          }),
          Bucket: this.getBucket(),
          Key: key,
          ContentType: contentType,
          // See bug, if used causes large files to hang: https://github.com/aws/aws-sdk-js-v3/issues/3915
          // ContentLength: contentLength,
          ContentDisposition: this.getContentDisposition(contentType),
          Body: body
        }
      });
      await upload.done();
      const endpoint = this.getPublicEndpoint(true);
      return `${endpoint}/${key}`;
    });
    _defineProperty(this, "getSignedUrl", async function (key) {
      let expiresIn = arguments.length > 1 && arguments[1] !== undefined ? arguments[1] : S3Storage.defaultSignedUrlExpires;
      const isDocker = _env.default.AWS_S3_UPLOAD_BUCKET_URL.match(/http:\/\/s3:/);
      const params = {
        Bucket: _this.getBucket(),
        Key: key
      };
      if (isDocker) {
        return `${_this.getPublicEndpoint()}/${key}`;
      } else {
        // Ensure expiration does not exceed AWS S3 Signature V4 limit of 7 days
        const clampedExpiresIn = Math.min(expiresIn, S3Storage.maxSignedUrlExpires);
        const command = new _clientS.GetObjectCommand(params);
        const url = await (0, _s3RequestPresigner.getSignedUrl)(_this.client, command, {
          expiresIn: clampedExpiresIn
        });
        if (_env.default.AWS_S3_ACCELERATE_URL) {
          return url.replace(_env.default.AWS_S3_UPLOAD_BUCKET_URL, _env.default.AWS_S3_ACCELERATE_URL);
        }
        return url;
      }
    });
    _defineProperty(this, "moveFile", async (fromKey, toKey) => {
      await this.client.send(new _clientS.CopyObjectCommand({
        Bucket: this.getBucket(),
        CopySource: `${_env.default.AWS_S3_UPLOAD_BUCKET_NAME}/${fromKey}`,
        Key: toKey
      }));
      await this.client.send(new _clientS.DeleteObjectCommand({
        Bucket: this.getBucket(),
        Key: fromKey
      }));
    });
    _defineProperty(this, "client", void 0);
    this.client = new _clientS.S3Client({
      bucketEndpoint: _env.default.AWS_S3_ACCELERATE_URL ? true : false,
      forcePathStyle: _env.default.AWS_S3_FORCE_PATH_STYLE,
      region: _env.default.AWS_REGION,
      endpoint: this.getEndpoint()
    });
  }
  async getPresignedPost(_ctx, key, acl, maxUploadSize) {
    let contentType = arguments.length > 4 && arguments[4] !== undefined ? arguments[4] : "image";
    const params = {
      Bucket: _env.default.AWS_S3_UPLOAD_BUCKET_NAME,
      Key: key,
      Conditions: (0, _compact.default)([["content-length-range", 0, maxUploadSize], ["starts-with", "$Content-Type", contentType], ["starts-with", "$Cache-Control", ""], ["starts-with", "$Content-Disposition", ""]]),
      Fields: {
        "Content-Disposition": this.getContentDisposition(contentType),
        key,
      },
      Expires: 3600
    };
    return (0, _s3PresignedPost.createPresignedPost)(this.client, params);
  }
  getPublicEndpoint(isServerUpload) {
    if (_env.default.AWS_S3_ACCELERATE_URL) {
      return _env.default.AWS_S3_ACCELERATE_URL;
    }
    (0, _invariant.default)(_env.default.AWS_S3_UPLOAD_BUCKET_NAME, "AWS_S3_UPLOAD_BUCKET_NAME is required");

    // lose trailing slash if there is one and convert fake-s3 url to localhost
    // for access outside of docker containers in local development
    const isDocker = _env.default.AWS_S3_UPLOAD_BUCKET_URL.match(/http:\/\/s3:/);
    const host = _env.default.AWS_S3_UPLOAD_BUCKET_URL.replace("s3:", "localhost:").replace(/\/$/, "");

    // support old path-style S3 uploads and new virtual host uploads by checking
    // for the bucket name in the endpoint url before appending.
    const isVirtualHost = host.includes(_env.default.AWS_S3_UPLOAD_BUCKET_NAME);
    if (isVirtualHost) {
      return host;
    }
    return `${host}/${isServerUpload && isDocker ? "s3/" : ""}${_env.default.AWS_S3_UPLOAD_BUCKET_NAME}`;
  }
  getUploadUrl(isServerUpload) {
    return this.getPublicEndpoint(isServerUpload);
  }
  getUrlForKey(key) {
    return `${this.getPublicEndpoint()}/${key}`;
  }
  async deleteFile(key) {
    await this.client.send(new _clientS.DeleteObjectCommand({
      Bucket: this.getBucket(),
      Key: key
    }));
  }
  getFileHandle(key) {
    return new Promise((resolve, reject) => {
      _tmp.default.dir((err, tmpDir) => {
        if (err) {
          return reject(err);
        }
        const tmpFile = _nodePath.default.join(tmpDir, "tmp");
        const dest = _fsExtra.default.createWriteStream(tmpFile);
        dest.on("error", reject);
        dest.on("finish", () => resolve({
          path: tmpFile,
          cleanup: () => _fsExtra.default.rm(tmpFile)
        }));
        void this.getFileStream(key).then(stream => {
          if (!stream) {
            return reject(new Error("No stream available"));
          }
          stream.on("error", error => {
            dest.end();
            reject(error);
          }).pipe(dest);
        });
      });
    });
  }
  getFileExists(key) {
    return this.client.send(new _clientS.HeadObjectCommand({
      Bucket: this.getBucket(),
      Key: key
    })).then(() => true).catch(() => false);
  }
  getFileStream(key, range) {
    return this.client.send(new _clientS.GetObjectCommand({
      Bucket: this.getBucket(),
      Key: key,
      Range: range ? `bytes=${range.start}-${range.end}` : undefined
    })).then(item => item.Body).catch(err => {
      _Logger.default.error("Error getting file stream from S3 ", err, {
        key
      });
      return null;
    });
  }
  getEndpoint() {
    if (_env.default.AWS_S3_ACCELERATE_URL) {
      return _env.default.AWS_S3_ACCELERATE_URL;
    }

    // support old path-style S3 uploads and new virtual host uploads by
    // checking for the bucket name in the endpoint url.
    if (_env.default.AWS_S3_UPLOAD_BUCKET_NAME) {
      const url = new URL(_env.default.AWS_S3_UPLOAD_BUCKET_URL);
      if (url.hostname.startsWith(_env.default.AWS_S3_UPLOAD_BUCKET_NAME + ".")) {
        _Logger.default.warn("AWS_S3_UPLOAD_BUCKET_URL contains the bucket name, this configuration combination will always point to AWS.\nRename your bucket or hostname if not using AWS S3.\nSee: https://github.com/outline/outline/issues/8025");
        return undefined;
      }
    }
    return _env.default.AWS_S3_UPLOAD_BUCKET_URL;
  }
  getBucket() {
    return _env.default.AWS_S3_ACCELERATE_URL || _env.default.AWS_S3_UPLOAD_BUCKET_NAME || "";
  }
}
exports.default = S3Storage;