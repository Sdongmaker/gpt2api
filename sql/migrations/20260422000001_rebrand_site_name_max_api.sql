-- +goose Up
-- +goose StatementBegin

-- 仅在站点名称仍为历史默认值 GPT2API 时升级为 MAX API;
-- 已被管理员自定义过的站点名保持不变。
UPDATE `system_settings`
SET `v` = 'MAX API'
WHERE `k` = 'site.name'
  AND COALESCE(`v`, '') = 'GPT2API';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- 仅回退由本迁移直接改写过的默认值。
UPDATE `system_settings`
SET `v` = 'GPT2API'
WHERE `k` = 'site.name'
  AND COALESCE(`v`, '') = 'MAX API';

-- +goose StatementEnd
