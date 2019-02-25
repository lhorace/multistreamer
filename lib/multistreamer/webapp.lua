-- luacheck: globals ngx networks
local ngx = ngx
local networks = networks
local lapis = require'lapis'
local app = lapis.Application()
local config = require'multistreamer.config'.get()
local db = require'lapis.db'

local redis = require'multistreamer.redis'
local publish = redis.publish

local User =    require'multistreamer.models.user'
local Account = require'multistreamer.models.account'
local Stream =  require'multistreamer.models.stream'
local StreamAccount = require'multistreamer.models.stream_account'
local SharedAccount = require'multistreamer.models.shared_account'
local SharedStream  = require'multistreamer.models.shared_stream'
local Webhook = require'multistreamer.models.webhook'
local version = require'multistreamer.version'

local respond_to = lapis.application.respond_to
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json

local WebsocketServer = require'multistreamer.websocket.server'

local tonumber = tonumber
local pairs = pairs
local len = string.len
local lower = string.lower
local format = string.format
local insert = table.insert
local find = string.find
local sub = string.sub
local sort = table.sort
local streams_dict = ngx.shared.streams
local status_dict = ngx.shared.status
local capture = ngx.location.capture
local ngx_log = ngx.log
local ngx_warn = ngx.WARN
local ngx_debug = ngx.DEBUG

local importexport = require'multistreamer.importexport'

local pid = ngx.worker.pid()

app.views_prefix = 'multistreamer.views'
app:enable('etlua')
app.layout = require'multistreamer.views.layout'

app:before_filter(function(self)
  self.version = version
  self.config = config
  self.networks = networks
  self.user = User.read_session(self)
  if self.session.status_msg then
    self.status_msg = self.session.status_msg
    self.session.status_msg = nil
  end
  if status_dict:get('processmgr_error') or status_dict:get('chatmgr_error') then
    self.status_msg = {
      type = 'error',
      msg = config.lang.restart_error,
    }
  end
  self.public_http_url = config.public_http_url
  self.http_prefix = config.http_prefix
  self.public_irc_hostname = config.public_irc_hostname
  self.public_irc_port = config.public_irc_port
  self.public_irc_ssl = config.public_irc_ssl
  if self.user and self.user:get_pref('lang') and self.config.langs[self.user:get_pref('lang')] then
    self.config.lang = self.config.langs[self.user:get_pref('lang')]
  end
end)

local function sort_accounts(a,b)
  return networks[a.network].displayname < networks[b.network].displayname
end

local function err_out(req, err)
  req.session.status_msg = { type = 'error', msg = err }
  return req:write({ redirect_to = req:url_for('site-root') })
end

local function plain_err_out(req,err,status)
  status = status or 404
  return req:write({
    layout = 'plain',
    content_type = 'text/plain',
    status = status
  }, err)
end

local function require_login(self)
  if not self.user then
    return false, 'not logged in'
  end
  return true, nil
end

local function get_all_streams_accounts(uuid)
  if not uuid then
    return false,false, 'UUID not provided'
  end
  local stream = Stream:find({ uuid = uuid })
  if not stream then
    return false,false, 'Stream not found'
  end
  local sas = stream:get_streams_accounts()
  local ret = {}
  for _,sa in pairs(sas) do
    local account = sa:get_account()
    insert(ret, { account, sa } )
  end
  return stream, ret, nil
end

app:match('login', config.http_prefix .. '/login', respond_to({
  GET = function(_)
    return { render = 'login' }
  end,
  POST = function(self)
    local user = User:login(self.params.username, self.params.password)
    if(user) then
      user:write_session(self)
      return { redirect_to = self:url_for('site-root') }
    else
      return { render = 'login' }
    end
  end,
}))

app:match('logout', config.http_prefix .. '/logout', function(self)
  User.unwrite_session(self)
  return { redirect_to = self:url_for('site-root') }
end)

app:match('stream-export', config.http_prefix .. '/stream/:id/export', respond_to({
  before = function(self)
    if not require_login(self) then return err_out(self,self.config.lang.login_required) end

    self.stream = Stream:find({ id = self.params.id })
    if not self.stream then
      return err_out(self,self.config.lang.stream_not_found)
    end
  end,
  GET = function(self)
    local t = importexport.export_stream(self,self.stream)
    return self:write({
      layout = 'plain',
      content_type = 'application/octet-stream',
      headers = {
        ['Content-Disposition'] = 'attachment; filename="'..  self.stream.name .. '.json"',
      },
      status = 200,
    }, to_json(t.json))
  end,
}))

app:match('stream-edit', config.http_prefix .. '/stream(/:id)', respond_to({
  before = function(self)
    if not require_login(self) then return err_out(self,self.config.lang.login_required) end

    if self.params.id then
      self.stream = Stream:find({ id = self.params.id })

      if not self.stream then
        return err_out(self,self.config.lang.stream_not_found)
      end

      self.stream_accounts = {}
      for _,v in pairs(self.stream:get_streams_accounts()) do
        local sa = v:get_account()
        if networks[sa.network] then
          insert(self.stream_accounts, sa)
        end
      end

      self.metadata_level = self.stream:check_meta(self.user)
      self.chat_level = self.stream:check_chat(self.user)

      self.stream_status = streams_dict:get(self.stream.id)
      if self.stream_status then
        self.stream_status = from_json(self.stream_status)
      else
        self.stream_status = {
            data_incoming = false,
            data_pushing = false,
            data_pulling = false,
        }
      end

      if self.metadata_level < 1 and self.chat_level < 1 then
        return err_out(self,self.config.lang.stream_not_found)
      end
    end

    local valid_subsets = {
      general = true,
      dashboard = true,
      accounts = true,
      permissions = true,
      advanced = true,
      webhooks = true,
    }

    if not self.stream then
      self.params.subset = 'general'
    elseif not self.params.subset then
      self.params.subset = 'dashboard'
    end

    if not self.params.tab then
      self.params.tab = self.params.subset
    end

    if not valid_subsets[self.params.subset] then
      self.params.subset = 'general'
    end

    if not valid_subsets[self.params.tab] then
      self.params.tab = 'general'
    end

    self.users = User:select('where id != ?',self.user.id)
    for i,other_user in pairs(self.users) do
      local ss = nil
      if self.stream then
        ss = SharedStream:find({ stream_id = self.stream.id, user_id = other_user.id})
      end
      if not ss then
        self.users[i].chat_level = 0
        self.users[i].metadata_level = 0
      else
        self.users[i].chat_level = ss.chat_level
        self.users[i].metadata_level = ss.metadata_level
      end
    end

    self.webhooks = self.stream and self.stream:get_webhooks() or {}
    self.webhook_types = Webhook.types
    self.webhook_events = Webhook.events

    self.accounts = {}
    self.stream_accounts = self.stream_accounts or {}

    local acc = self.user:get_accounts()
    if not acc then acc = {} end
    for _,account in pairs(acc) do
      if networks[account.network] then
        insert(self.accounts,account)
      end
    end

    local sas = self.user:get_shared_accounts()
    for _,sa in pairs(sas) do
      local account = sa:get_account()
      local u = account:get_user()
      account.shared = true
      account.shared_from = u.username
      if networks[account.network] then
        insert(self.accounts,account)
      end
    end
    sort(self.accounts, sort_accounts)
    sort(self.stream_accounts, sort_accounts)
    self.public_rtmp_url = config.public_rtmp_url
    self.rtmp_prefix = config.rtmp_prefix
  end,
  GET = function(self)
    if not self.params.subset or self.params.subset == 'general' then
      return { render = 'stream' }
    elseif self.params.subset == 'accounts' then
      return { render = 'stream-accounts' }
    elseif self.params.subset == 'dashboard' then
      return { render = 'stream-dashboard' }
    elseif self.params.subset == 'permissions' then
      return { render = 'stream-permissions' }
    elseif self.params.subset == 'advanced' then
      return { render = 'stream-advanced' }
    elseif self.params.subset == 'webhooks' then
      return { render = 'stream-webhooks' }
    end
  end,
  POST = function(self)
    local stream_updated = false

    if self.params.subset == 'general' then -- {{{
      local preview_required = nil
      local stream_name = nil
      if self.stream then
        if not self.stream:check_owner(self.user) then
          return err_out(self,self.config.lang.stream_not_found)
        end
        preview_required = self.stream.preview_required
        stream_name = self.stream.name
      end
      local stream, err = Stream:save_stream(self.user,self.stream,self.params)
      if not self.stream then
        if err then
          self.session.status_msg = { type = 'error', msg = self.config.lang.stream_create_error:format(err) }
        else
          self.session.status_msg = { type = 'success', msg = self.config.lang.stream_created }
          self.stream = stream
          stream_updated = true
        end
      else
        if err then
          self.session.status_msg = { type = 'error', msg = self.config.lang.stream_update_error:format(err) }
        else
          if stream_name ~= stream.name or
             preview_required ~= stream.preview_required then
            self.session.status_msg = { type = 'success', msg = self.config.lang.stream_updated }
            stream_updated = true
          end
          self.stream = stream
        end
      end
    end -- }}}

    if self.params.subset == 'accounts' then -- {{{
      if not self.stream:check_owner(self.user) then
        return err_out(self,self.config.lang.stream_not_found)
      end
      local accounts = {}
      for _,account in pairs(self.accounts) do
        if self.params['account.'..account.id] and self.params['account.'..account.id] == 'on' then
          accounts[account.id] = true
        else
          accounts[account.id] = false
        end
      end
      if Stream:save_accounts(self.user, self.stream, accounts) == true then
        stream_updated = true
        self.session.status_msg = { type = 'success', msg = self.config.lang.accounts_updated }
      end
    end -- }}}

    if self.params.subset == 'advanced' then -- {{{
      if not self.stream:check_owner(self.user) then
        return err_out(self,self.config.lang.stream_not_found)
      end

      if self.params['export_button'] ~= nil then
        return self:write({ redirect_to = self:url_for('stream-export', {id = self.stream.id}) })
      end

      if self.params['import_file'] ~= nil and self.params['import_file'].content ~= nil and len(self.params['import_file'].content) > 0 then
        local js = from_json(self.params['import_file'].content)
        if js ~= nil then
          js.stream.name = nil
          local r = importexport.import_stream(self,self.stream,js.stream)
          if r.status == 200 then
            self.session.status_msg = { type = 'success', msg = self.config.lang.stream_import_success }
          else
            self.session.status_msg = { type = 'error', msg = self.config.lang.stream_import_error }
          end
        end
      end

      if not self.params.ffmpeg_pull_args or len(self.params.ffmpeg_pull_args) == 0 then
        self.stream:update({ffmpeg_pull_args = db.NULL})
        self.session.status_msg = { type = 'success', msg = self.config.lang.ffmpeg_pull_removed }
        stream_updated = true
      else
        self.stream:update({ffmpeg_pull_args = self.params.ffmpeg_pull_args})
        self.session.status_msg = { type = 'success', msg = self.config.lang.ffmpeg_pull_updated }
        stream_updated = true
      end
    end -- }}}

    if self.params.subset == 'permissions' then -- {{{
      if not self.stream:check_owner(self.user) then
        return err_out(self,self.config.lang.stream_not_found)
      end
      for _,other_user in pairs(self.users) do
        local chat_level = 0
        local metadata_level = 0
        if self.params['user.'..other_user.id..'.chat'] then
          chat_level = tonumber(self.params['user.'..other_user.id..'.chat'])
        end
        if self.params['user.'..other_user.id..'.metadata'] then
          metadata_level = tonumber(self.params['user.'..other_user.id..'.metadata'])
        end
        local ss = SharedStream:find({ stream_id = self.stream.id, user_id = other_user.id })
        if ss then
          if ss.chat_level ~= chat_level or ss.metadata_level ~= metadata_level then
            stream_updated = true
            self.session.status_msg = { type = 'success', msg = self.config.lang.share_updated }
          end
          ss:update({chat_level = chat_level, metadata_level = metadata_level})
        else
          SharedStream:create({
            stream_id = self.stream.id,
            user_id = other_user.id,
            chat_level = chat_level,
            metadata_level = metadata_level,
          })
          if chat_level > 0 or metadata_level > 0 then
            stream_updated = true
            self.session.status_msg = { type = 'success', msg = self.config.lang.share_updated }
          end
        end
      end
    end -- }}}

    if self.params.subset == 'webhooks' then -- {{{
      if not self.stream:check_owner(self.user) then
        return err_out(self,self.config.lang.stream_not_found)
      end
      local webhook_created = false
      local webhook_updated = false
      local webhook_status = 'success'
      local webhook_message = ''
      if self.params['webhook.0.url'] and len(self.params['webhook.0.url']) > 0 then
        if not self.params['webhook.0.type'] or self.params['webhook.0.type'] == '-1' then
          webhook_status = 'error'
          webhook_message = 'Failed to add webhook: "type" not set. '
        else
          local p = {}
          p.stream_id = self.stream.id
          p.url = self.params['webhook.0.url']
          p.type = self.params['webhook.0.type']
          p.notes = self.params['webhook.0.notes']
          p.events = {}
          for _,v in ipairs(self.webhook_events) do
            if self.params['webhook.0.event.' .. v.value] and
               self.params['webhook.0.event.' .. v.value] == 'on' then
              p.events[v.value] = true
            else
              p.events[v.value] = false
            end
          end
          Webhook:create(p)
          webhook_created = true
          webhook_message = 'Webhook added. '
        end
      end

      for _,v in ipairs(self.webhooks) do
        if len(self.params['webhook.' .. v.id .. '.url']) <= 0 then
          webhook_message = webhook_message .. 'Deleted webhook ' .. v.url .. '. '
          v:delete()
        else
          local updated = false
          if not self.params['webhook.' .. v.id .. '.notes'] then
            self.params['webhook.' .. v.id .. '.notes'] = ''
          end
          if not self.params['webhook.' .. v.id .. '.type'] then
            self.params['webhook.' .. v.id .. '.type'] = ''
          end

          if not v.notes then
            v.notes = ''
          end

          if v.notes ~= self.params['webhook.' .. v.id .. '.notes'] or
             v.type ~= self.params['webhook.' .. v.id .. '.type'] then
            updated = true
          end
          v.notes = self.params['webhook.'..v.id..'.notes']
          v.type = self.params['webhook.' .. v.id .. '.type']
          for _,e in ipairs(self.webhook_events) do
            if self.params['webhook.' .. v.id .. '.event.' .. e.value] and
               self.params['webhook.' .. v.id .. '.event.' .. e.value] == 'on' then
              if v:check_event(e.value) == false then
                updated = true
              end
              v:enable_event(e.value)
            else
              if v:check_event(e.value) == true then
                updated = true
              end
              v:disable_event(e.value)
            end
          end
          v:save()
          if updated == true then
            webhook_message = webhook_message .. 'Updated webhook ' .. v.url .. '. '
            webhook_updated = true
          end
        end
      end
      if len(webhook_message) > 0 then
        self.session.status_msg = { type = webhook_status, msg = webhook_message }
      end

      if webhook_updated == true or webhook_created == true then
        stream_updated = true
      end
    end -- }}}

    if self.params.subset == 'dashboard' then -- {{{
      if self.metadata_level < 2 then
        return err_out(self,self.config.lang.stream_not_found)
      end

      if self.params.title then
        if self.params.title ~= self.stream:get('title') then
          stream_updated = true
        end
        self.stream:set('title',self.params.title)
      end
      if self.params.description then
        if self.params.description ~= self.stream:get('description') then
          stream_updated = true
        end
        self.stream:set('description',self.params.description)
      end

      for _,account in pairs(self.stream_accounts) do
        local sa = self.stream:get_stream_account(account)
        local sa_keys = sa:get_all()
        local ffmpeg_args = self.params['ffmpeg_args' .. '.' .. account.id]
        if ffmpeg_args and len(ffmpeg_args) > 0 then
          sa:update({ffmpeg_args = ffmpeg_args })
          stream_updated = true
        else
          sa:update({ffmpeg_args = db.NULL })
          stream_updated = true
        end

        local metadata_fields = networks[account.network].metadata_fields()
        if not metadata_fields then metadata_fields = {} end
        for _,field in pairs(metadata_fields) do
          local v = self.params[field.key .. '.' .. account.id]
          -- normalize checkbox to true/false
          if field.type == 'checkbox' then
            if v and len(v) > 0 then
              v = true
            else
              v = false
            end
            if sa_keys[field.key] == 'true' then
              sa_keys[field.key] = true
            elseif sa_keys[field.key] == 'false' then
              sa_keys[field.key] = false
            else
              sa_keys[field.key] = nil
            end
          else
            if not v or len(v) == 0 then
              v = nil
            end
          end

          if v == nil then
            if sa_keys[field.key] ~= nil then
              sa:unset(field.key)
              stream_updated = true
            end
          else
            if sa_keys[field.key] ~= v then
              sa:set(field.key,v)
              stream_updated = true
            end
          end
        end
      end

      if self.params['customPullBtn'] ~= nil then
        self.stream_status.data_pulling = true
        streams_dict:set(self.stream.id, to_json(self.stream_status))
        publish('process:start:pull', {
          worker = pid,
          id = self.stream.id,
        })
        self.session.status_msg = { type = 'success', msg = self.config.lang.puller_started }
        return { redirect_to = self:url_for('stream-edit', { id = self.stream.id }) .. '?subset=dashboard' }
      end

      if self.params['customPullBtnStop'] ~= nil then
        self.stream_status.data_pulling = false
        streams_dict:set(self.stream.id, to_json(self.stream_status))
        publish('process:end:pull', {
          id = self.stream.id,
        })
        self.session.status_msg = { type = 'success', msg = self.config.lang.puller_stopped }
        return { redirect_to = self:url_for('stream-edit', { id = self.stream.id }) .. '?subset=dashboard' }
      end

      if stream_updated then
        self.session.status_msg = { type = 'success', msg = self.config.lang.stream_saved }
      end

      -- is there incoming data, and the user clicked the golivebutton? start the stream
      if self.stream_status.data_incoming == true and
         self.stream_status.data_pushing == false and
         self.params['goLiveBtn'] ~= nil
      then
        self.stream_status.data_pushing = true
        local sas = {}

        for _,account in pairs(self.accounts) do
          local sa = StreamAccount:find({stream_id = self.stream.id, account_id = account.id})
          if sa then
            local rtmp_url, err = networks[account.network].publish_start(account:get_keystore(),sa:get_keystore())
            if (not rtmp_url) or err then
              self.session.status_msg = { type = 'error', msg = self.config.lang.pusher_error:format(err)}
              ngx_log(ngx_warn,format(
                'app:publish-start: failed to start %s (%s): %s',
                account.name,
                networks[account.network].name,
                err
              ))
              return { redirect_to = self:url_for('stream-edit', { id = self.stream.id }) .. '?subset=dashboard' }
            end
            sa:update({rtmp_url = rtmp_url})
            insert(sas, sa)
          end
        end

        publish('process:start:push', {
          worker = pid,
          id = self.stream.id,
        })

        publish('stream:start', {
          worker = pid,
          id = self.stream.id,
          status = self.stream_status,
        })

        for _,v in pairs(self.stream:get_webhooks()) do
          v:fire_event('stream:start', sas)
        end

        self.session.status_msg = { type = 'success', msg = self.config.lang.stream_started }
      end

      if self.stream_status.data_pushing == true and self.params['stopLiveBtn'] ~= nil then
        self.stream_status.data_pushing = false
        local account_ids = {}
        for _,account in pairs(self.accounts) do
          local sa = StreamAccount:find({ stream_id = self.stream.id, account_id = account.id })
          if sa then
            insert(account_ids,account.id)
          end
        end

        publish('stream:end', {
          id = self.stream.id,
        })

        publish('process:end:push', {
          id = self.stream.id,
          accounts = account_ids,
        })

        for _,v in pairs(self.stream:get_webhooks()) do
          v:fire_event('stream:end')
        end
        self.session.status_msg = { type = 'success', msg = self.config.lang.stream_stopped }
      end

      streams_dict:set(self.stream.id, to_json(self.stream_status))
    end -- }}}

    if stream_updated == true then
      publish('stream:update',{ id = self.stream.id })
    end

    if not self.stream then
      return { redirect_to = self:url_for('stream-edit') }
    end

    return { redirect_to = self:url_for('stream-edit', { id = self.stream.id }) .. '?subset=' .. self.params.tab }
  end,
}))

app:match('profile-edit', config.http_prefix .. '/profile/:id', respond_to({
  before = function(self)
    if not require_login(self) then return err_out(self,self.config.lang.login_required) end
  end,
  GET = function(_)
    return { render = 'profile' }
  end,
  POST = function(self)
    if self.params['resetTokenBtn'] ~= nil then
      self.user:reset_token()
    end
    self.user:save_pref('night_mode',tonumber(self.params['night_mode']) == 1)
    self.user:save_pref('lang',self.params['lang'])
    self.config.lang = self.config.langs[self.user:get_pref('lang')]
    return { render = 'profile' }
  end,
}))

app:match('metadata-dummy', config.http_prefix .. '/metadata', function(self)
  return { redirect_to = self:url_for('site-root') }
end)

app:match('metadata-edit', config.http_prefix .. '/metadata/:id', respond_to({
  GET = function(self)
    return { redirect_to = self:url_for('stream-edit', { id = self.params.id }) }
  end,
  POST = function(self)
    return { redirect_to = self:url_for('stream-edit', { id = self.params.id }) }
  end,
}))

app:match('publish-start',config.http_prefix .. '/on-publish', respond_to({
  GET = function(self)
    return plain_err_out(self,'Not Found')
  end,
  POST = function(self)
    ngx_log(ngx_debug,'app:on-publish: ' .. to_json(self.params))
    local stream, sas, err = get_all_streams_accounts(self.params.name)
    if not stream then
      return plain_err_out(self,err)
    end

    local stream_status = streams_dict:get(stream.id)
    if stream_status then
      stream_status = from_json(stream_status)
    else
      stream_status = {
        data_incoming = false,
        data_pushing = false,
        data_pulling = false,
      }
    end

    stream_status.data_incoming = true
    streams_dict:set(stream.id, to_json(stream_status))

    if stream_status.data_pushing == true then -- this happens if OBS was disconnected and reconnected
                                               -- we don't want to create new videos, just restart ffmpeg
      publish('process:start:repush', {
        id = stream.id,
      })
      return plain_err_out(self,'OK',200)
    end

    if stream.preview_required == 0 and #sas > 0 then
      local hook_sas = {}
      for _,v in pairs(sas) do
        local account = v[1]
        local sa = v[2]
        local rtmp_url, rtmp_err = networks[account.network].publish_start(account:get_keystore(),sa:get_keystore())
        if (not rtmp_url) or rtmp_err then
          ngx_log(ngx_warn,format(
            'app:publish-start: failed to start %s (%s): %s',
            account.name,
            networks[account.network].name,
            rtmp_err
          ))
          -- reset data_incoming to false
          stream_status.data_incoming = false
          streams_dict:set(stream.id, to_json(stream_status))
          return plain_err_out(self,rtmp_err)
        end
        sa:update({rtmp_url = rtmp_url})
        insert(hook_sas, sa)
      end

      stream_status.data_pushing = true
      streams_dict:set(stream.id, to_json(stream_status))

      publish('process:start:push', {
        worker = pid,
        delay = 5,
        id = stream.id,
      })

      for _,v in pairs(stream:get_webhooks()) do
        v:fire_event('stream:start', hook_sas)
      end

    end

    publish('stream:start', {
      worker = pid,
      id = stream.id,
      status = stream_status,
    })

    return plain_err_out(self,'OK',200)
 end,
}))

app:match('on-update',config.http_prefix .. '/on-update', respond_to({

  GET = function(self)
    return plain_err_out(self,'Not Found')
  end,
  POST = function(self)
    ngx_log(ngx_debug,'app:on-update: ' .. to_json(self.params))

    if self.params.call == 'play' or self.params.call == 'update_play' then
      return plain_err_out(self,'OK',200)
    end

    local stream, sas, err = get_all_streams_accounts(self.params.name)
    if not stream then
      return plain_err_out(self,err)
    end

    local stream_status = streams_dict:get(stream.id)
    if stream_status then
      stream_status = from_json(stream_status)
    else
      stream_status = {
        data_incoming = false,
        data_pushing = false,
        data_pulling = false,
      }
    end

    if stream_status.data_incoming == false and
       stream_status.data_pushing == false then
      return plain_err_out(self,'Error')
    end

    if stream_status.data_pushing == false then
      return plain_err_out(self,'OK',200)
    end

    for _,v in pairs(sas) do
      local account = v[1]
      local sa = v[2]
      local _, account_err = networks[account.network].notify_update(account:get_keystore(),sa:get_keystore())
      if err then
        return plain_err_out(self,account_err)
      end
    end

    return plain_err_out(self,'OK',200)
 end,
}))

app:post('publish-stop',config.http_prefix .. '/on-done',function(self)
  ngx_log(ngx_debug,'app:on-done: ' .. to_json(self.params))
  local stream, sas, err = get_all_streams_accounts(self.params.name)
  if not stream then
    return plain_err_out(self,err)
  end
  local stream_status = streams_dict:get(stream.id)
  if stream_status then
    stream_status = from_json(stream_status)
  else
    stream_status = {
      data_incoming = false,
      data_pushing = false,
      data_pulling = false,
    }
  end

  local accounts = {}
  for _,sa in pairs(sas) do
    insert(accounts,sa.account_id)
  end

  publish('stream:end', {
    id = stream.id,
  })

  for _,v in pairs(stream:get_webhooks()) do
    v:fire_event('stream:end')
  end

  streams_dict:set(stream.id,nil)

  for _,v in pairs(sas) do
    local account = v[1]
    local sa = v[2]

    sa:update({rtmp_url = db.NULL})
    networks[account.network].publish_stop(account:get_keystore(),sa:get_keystore())
  end

  return plain_err_out(self,'OK',200)
end)

app:get('site-root', config.http_prefix .. '/', function(self)
  if not require_login(self) then
    return { redirect_to = 'login' }
  end

  self.accounts = {}
  self.streams = self.user:get_streams()
  local accounts = self.user:get_accounts()

  if not accounts then accounts = {} end
  if not self.streams then self.streams = {} end

  local sas = self.user:get_shared_accounts()

  for _,sa in pairs(sas) do
    local account = sa:get_account()
    if networks[account.network] then
      local u = account:get_user()
      account.shared = true
      account.shared_from = u.username
      insert(self.accounts,account)
    end
  end

  for _,v in pairs(accounts) do
    if networks[v.network] then
      v.errors = networks[v.network].check_errors(v:get_keystore())
      insert(self.accounts,v)
    end
  end

  local sss = self.user:get_shared_streams()
  for _,ss in pairs(sss) do
    if ss.chat_level > 0 or ss.metadata_level > 0 then
      local stream = ss:get_stream()
      local u = stream:get_user()
      stream.shared = true
      stream.shared_from = u.username
      stream.chat_level = ss.chat_level
      stream.metadata_level = ss.metadata_level
      insert(self.streams,stream)
    end
  end

  for _,v in pairs(self.streams) do
    local stream_status = streams_dict:get(v.id)
    if stream_status then
      stream_status = from_json(stream_status)
    else
      stream_status = { data_pushing = false }
    end
    if stream_status.data_pushing == true then
      v.live = true
    else
      v.live = false
    end
  end


  sort(self.accounts, sort_accounts)

  sort(self.streams,function(a,b)
    if a.live ~= b.live then
      return a.live
    end
    return lower(a.name) < lower(b.name)
  end)

  return { render = 'index' }
end)

app:match('stream-delete', config.http_prefix .. '/stream/:id/delete', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end
    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return err_out(self,self.config.lang.stream_not_auth)
    end
    local owner_ok, _ = stream:check_owner(self.user)
    if not owner_ok then
      return err_out(self,self.config.lang.stream_not_auth)
    end

    self.stream = stream
  end,
  GET = function(_)
    return { render = 'stream-delete' }
  end,
  POST = function(self)
    self.stream.user = self.stream:get_user()
    local sas = self.stream:get_streams_accounts()
    for _,sa in pairs(sas) do
      sa:get_keystore():unset_all()
      sa:delete()
    end
    for _,ss in pairs(self.stream:get_stream_shares()) do
      ss:delete()
    end
    self.stream:get_keystore():unset_all()
    for _,wh in pairs(self.stream:get_webhooks()) do
      wh:delete()
    end
    publish('stream:delete',{
      id = self.stream.id,
      user = {
        username = self.stream.user.username,
      },
      slug = self.stream.slug
    })
    self.stream:delete()
    self.session.status_msg = { type = 'success', msg = config.lang.stream_removed }
    return { redirect_to = self:url_for('site-root') }
  end
}))

app:match('stream-chat', config.http_prefix .. '/stream/:id/chat', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end

    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return err_out(self, self.config.lang.chat_not_auth)
    end
    local level = stream:check_chat(self.user)
    if level == 0 then
      return err_out(self, self.config.lang.chat_not_auth)
    end
    self.stream = stream
  end,
  GET = function(_)
    return { layout = 'chatlayout', render = 'chat' }
  end,
}))

app:match('stream-chat-widget-config', config.http_prefix .. '/stream/:id/chat/widget', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end

    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return err_out(self, self.config.lang.chat_not_auth)
    end
    local level = stream:check_chat(self.user)
    if level == 0 then
      return err_out(self, self.config.lang.chat_not_auth)
    end
    self.stream = stream
  end,
  GET = function(_)
    return { layout = 'simplelayout', render = 'chat-widget-config' }
  end,
}))

app:match('stream-chat-preview', config.http_prefix .. '/chat/preview', respond_to({
  GET = function(self)
    self.params.widget = true
    return { layout = 'chatlayout', render = 'chat' }
  end,
}))

app:match('stream-stats', config.http_prefix .. '/stats', respond_to({
  GET = function(self)
    local res = capture(config.http_prefix .. '/stats_raw')
    local b = ''
    local buf = ''
    local s, e, u, stream
    local n = 1
    repeat
      s, e, u = find(res.body,"<name>([^<]+)</name>",n)
      if s then
        b = b .. sub(res.body,n,e)
        n = e + 1
        stream = Stream:find({ uuid = u })
        if stream then
          b = b .. '\n<user>' .. stream:get_user().username .. '</user>'
          b = b .. '\n<title>' .. stream.name .. '</title>'
        end
      end
    until not s
    b = b .. sub(res.body,n)

    n = 1
    repeat
      s, e, f = find(b,"<flashver>([^<]+)</flashver>",n)
      if s then
        buf = buf .. sub(b,n,e)
        n = e + 1
        local _, _, account_id = find(f,"accountid:(.+)")
        if account_id then
          local account = Account:find(account_id)
          buf = buf .. '<network>' .. account.network .. '</network>'
          buf = buf .. '<name>' .. account.name .. '</name>'
        end
      end
    until not s
    buf = buf .. sub(b,n)

    return plain_err_out(self,buf,200)
  end,
}))


app:match('stream-video', config.http_prefix .. '/stream/:id/video(/:fn)', respond_to({
  before = function(self)
    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return plain_err_out(self, self.config.lang.stream_not_found)
    end
    local ok = streams_dict:get(stream.id)
    if ok == nil or ok == 0 then
      return plain_err_out(self, self.config.lang.stream_not_live, 404)
    end
    self.stream = stream
  end,
  GET = function(self)
    local fn = self.params.fn or 'index.m3u8'

    local res = capture(config.http_prefix .. '/video_raw/' .. self.stream.uuid .. '/' .. fn)
    if res then
      if res.status == 302 then
        return plain_err_out(self, self.config.lang.stream_not_live, 404)
      end
      return self:write({
        layout = 'plain',
        content_type = res.header['content-type'],
        status = res.status,
      }, res.body)
    end
    return plain_err_out(self,'An error occured', 500)
  end,
}))

app:match('stream-ws', config.http_prefix .. '/ws/:id',respond_to({
  before = function(self)
    if not require_login(self) then
      return plain_err_out(self,'Not authorized', 403)
    end
    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return plain_err_out(self,'Not authorized', 403)
    end
    local chat_level = stream:check_chat(self.user)
    if chat_level == 0 then
      return plain_err_out(self,'Not authorized', 403)
    end
    self.chat_level = chat_level
    self.stream = stream
  end,
  GET = function(self)
    local wb_server = WebsocketServer.new(self.user,self.stream,self.chat_level)
    wb_server:run()
  end,
}))


app:match('account-delete', config.http_prefix .. '/account/:id/delete', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end
    local account = Account:find({ id = self.params.id })
    if not account or not account:check_user(self.user) then
      return err_out(self,self.config.lang.account_not_auth)
    end
    if not account:check_owner(self.user) then
      account.shared = true
    end
    self.account = account
  end,
  GET = function(_)
    return { render = "account-delete" }
  end,
  POST = function(self)
    local sas = self.account:get_streams_accounts()
    for _,sa in pairs(sas) do
      if self.account.shared then
        if sa:get_stream():get_user().id == self.user.id then
          sa:get_keystore():unset_all()
          sa:delete()
        end
      else
        sa:get_keystore():unset_all()
        sa:delete()
      end
    end

    if self.account.shared then
      local sa = SharedAccount:find({
        account_id = self.account.id,
        user_id = self.user.id,
      })
      sa:delete()
      self.session.status_msg = { type = 'success', msg = self.config.lang.account_removed }
    else
      local ssas = self.account:get_shared_accounts()
      if not ssas then ssas = {} end
      for _,sa in pairs(ssas) do
        sa:delete()
      end
      self.account:get_keystore():unset_all()
      self.account:delete()
      self.session.status_msg = { type = 'success', msg = self.config.lang.account_deleted }
    end
    return { redirect_to = self:url_for('site-root') }
  end,
}))

app:match('stream-share',config.http_prefix .. '/stream/:id/share', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end
    local stream = Stream:find({ id = self.params.id })
    if not stream or not stream:check_owner(self.user) then
      return err_out(self,self.config.lang.stream_not_found)
    end
    self.stream = stream
  end,
  GET = function(_)
    return { render = 'stream-share' }
  end,
  POST = function(self)
    self.session.status_msg = { type = 'success', msg = self.config.lang.share_updated }
    return { redirect_to = self:url_for('stream-share', { id = self.stream.id }) }
  end,
}))

app:match('account-share', config.http_prefix .. '/account/:id/share', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end

    local account = Account:find({ id = self.params.id })
    if not account or not account:check_owner(self.user) or not networks[account.network].allow_sharing then
      return err_out(self,self.config.lang.account_not_share)
    end
    self.account = account
    self.users = User:select('where id != ?',self.user.id)
    for i,other_user in pairs(self.users) do
      local sa = SharedAccount:find({ account_id = self.account.id, user_id = other_user.id})
      if not sa then
        self.users[i].shared = false
      else
        self.users[i].shared = true
      end
    end
  end,
  GET = function(_)
    return { render = 'account-share' }
  end,
  POST = function(self)
    for _,other_user in pairs(self.users) do
      if self.params['user.'..other_user.id] and self.params['user.'..other_user.id] == 'on' then
        self.account:share(other_user.id)
      else
        self.account:unshare(other_user.id)
      end
    end
    self.session.status_msg = { type = 'success', msg = self.config.lang.share_updated }
    return { redirect_to = self:url_for('account-share', { id = self.account.id }) }

  end,
}))


for _,m in networks() do
  if m.endpoints then
    for url, func_table in pairs(m.endpoints) do
      app:match('endpoint-' .. m.name .. '-' .. url, config.http_prefix .. '/util/' .. m.name .. url, respond_to(func_table))
    end
  end
  if m.register_oauth then
    app:match('auth-'..m.name, config.http_prefix .. '/auth/' .. m.name, respond_to({
      GET = function(self)
        local _, sa, err = m.register_oauth(self.params)
        if err then return err_out(self,err) end

        self.session.status_msg = { type = 'success', msg = self.config.lang.account_saved }
        if sa then
          return { redirect_to = self:url_for('stream-edit', { id = sa.stream_id }) .. '?subset=accounts' }
        end
        return { redirect_to = self:url_for('site-root') }
      end,
    }))
  elseif m.create_form then
    app:match('account-'..m.name, config.http_prefix .. '/account/' .. m.name .. '(/:id)', respond_to({
      before = function(self)
        self.network = m
        if self.params.id then
          self.account = Account:find({ id = self.params.id })
          local ok, err = self.account:check_owner(self.user)
          if not ok then return err_out(self,err) end
          ok, err = self.account:check_network(self.network)
          if not ok then return err_out(self,err) end
        end
      end,
      GET = function(_)
        return { render = 'account' }
      end,
      POST = function(self)
        local account, sa, err = m.save_account(self.user, self.account, self.params)
        if err then return err_out(self, err) end
        if self.params.ffmpeg_args and len(self.params.ffmpeg_args) > 0 then
          account:update({ ffmpeg_args = self.params.ffmpeg_args })
        else
          account:update({ ffmpeg_args = db.NULL })
        end
        self.session.status_msg = { type = 'success', msg = self.config.lang.account_saved }
        if sa then
          return { redirect_to = self:url_for('stream-edit', { id = sa.stream_id }) .. '?subset=accounts' }
        end
        return { redirect_to = self:url_for('site-root') }
      end,
    }))
  end
end

app:get('splat',  '*', function(self)
  return { redirect_to = self:url_for('site-root') }
end)

return app
