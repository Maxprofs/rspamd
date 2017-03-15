--[[
Copyright (c) 2017, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

local util = require "rspamd_util"
local ipairs = ipairs
local pairs = pairs
local table = table
local tostring = tostring
local tonumber = tonumber
local fun = require "fun"
local E = {}

local rcvd_cb_id = rspamd_config:register_symbol{
  name = 'CHECK_RECEIVED',
  type = 'callback',
  callback = function(task)
    local cnts = {
      [1] = 'ONE',
      [2] = 'TWO',
      [3] = 'THREE',
      [5] = 'FIVE',
      [7] = 'SEVEN',
      [12] = 'TWELVE'
    }
    local def = 'ZERO'
    local received = task:get_received_headers()
    local nreceived = fun.reduce(function(acc, rcvd)
        return acc + 1
      end, 0, fun.filter(function(h)
        return not h['artificial']
      end, received))

    for k,v in pairs(cnts) do
      if nreceived >= tonumber(k) then
        def = v
      end
    end

    task:insert_result('RCVD_COUNT_' .. def, 1.0, tostring(nreceived))
  end
}

rspamd_config:register_symbol{
  name = 'RCVD_COUNT_ZERO',
  score = 0.0,
  parent = rcvd_cb_id,
  type = 'virtual',
  description = 'No received',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCVD_COUNT_ONE',
  score = 0.0,
  parent = rcvd_cb_id,
  type = 'virtual',
  description = 'One received',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCVD_COUNT_TWO',
  score = 0.0,
  parent = rcvd_cb_id,
  type = 'virtual',
  description = 'Two received',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCVD_COUNT_THREE',
  score = 0.0,
  parent = rcvd_cb_id,
  type = 'virtual',
  description = '3-5 received',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCVD_COUNT_FIVE',
  score = 0.0,
  parent = rcvd_cb_id,
  type = 'virtual',
  description = '5-7 received',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCVD_COUNT_SEVEN',
  score = 0.0,
  parent = rcvd_cb_id,
  type = 'virtual',
  description = '7-11 received',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCVD_COUNT_TWELVE',
  score = 0.0,
  parent = rcvd_cb_id,
  type = 'virtual',
  description = '12+ received',
  group = 'header',
}

local prio_cb_id = rspamd_config:register_symbol {
  name = 'HAS_X_PRIO',
  type = 'callback',
  callback = function (task)
     local cnts = {
      [1] = 'ONE',
      [2] = 'TWO',
      [3] = 'THREE',
      [5] = 'FIVE',
    }
    local def = 'ZERO'
    local xprio = task:get_header('X-Priority');
    if not xprio then return false end
    local _,_,x = xprio:find('^%s?(%d+)');
    if (x) then
      x = tonumber(x)
      for k,v in pairs(cnts) do
        if x >= tonumber(k) then
          def = v
        end
      end
      task:insert_result('HAS_X_PRIO_' .. def, 1.0, tostring(x))
    end
  end
}
rspamd_config:register_symbol{
  name = 'HAS_X_PRIO_ZERO',
  score = 0.0,
  parent = prio_cb_id,
  type = 'virtual',
  description = 'Priority 0',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'HAS_X_PRIO_ONE',
  score = 0.0,
  parent = prio_cb_id,
  type = 'virtual',
  description = 'Priority 1',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'HAS_X_PRIO_TWO',
  score = 0.0,
  parent = prio_cb_id,
  type = 'virtual',
  description = 'Priority 2',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'HAS_X_PRIO_THREE',
  score = 0.0,
  parent = prio_cb_id,
  type = 'virtual',
  description = 'Priority 3-4',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'HAS_X_PRIO_FIVE',
  score = 0.0,
  parent = prio_cb_id,
  type = 'virtual',
  description = 'Priority 5+',
  group = 'header',
}

local check_replyto_id = rspamd_config:register_callback_symbol('CHECK_REPLYTO', 1.0,
  function (task)
    local replyto = task:get_header('Reply-To')
    if not replyto then return false end
    local rt = util.parse_mail_address(replyto)
    if not (rt and rt[1]) then
      task:insert_result('REPLYTO_UNPARSEABLE', 1.0)
      return false
    else
      task:insert_result('HAS_REPLYTO', 1.0)
      local rta = rt[1].addr
      if rta then
        -- Check if Reply-To address starts with title seen in display name
        local sym = task:get_symbol('FROM_NAME_HAS_TITLE')
        local title = (((sym or E)[1] or E).options or E)[1]
        if title then
          rta = rta:lower()
          if rta:find('^' .. title) then
            task:insert_result('REPLYTO_EMAIL_HAS_TITLE', 1.0)
          end
        end
      end
    end

    -- See if Reply-To matches From in some way
    local from = task:get_from(2)
    local from_h = task:get_header('From')
    if not (from and from[1]) then return false end
    if (from_h and from_h == replyto) then
      -- From and Reply-To are identical
      task:insert_result('REPLYTO_EQ_FROM', 1.0)
    else
      if (from and from[1]) then
        -- See if From and Reply-To addresses match
        if (from[1].addr:lower() == rt[1].addr:lower()) then
          task:insert_result('REPLYTO_ADDR_EQ_FROM', 1.0)
        elseif from[1].domain and rt[1].domain then
          if (from[1].domain:lower() == rt[1].domain:lower()) then
            task:insert_result('REPLYTO_DOM_EQ_FROM_DOM', 1.0)
          else
            task:insert_result('REPLYTO_DOM_NEQ_FROM_DOM', 1.0)
          end
        end
        -- See if the Display Names match
        if (from[1].name and rt[1].name and from[1].name:lower() == rt[1].name:lower()) then
          task:insert_result('REPLYTO_DN_EQ_FROM_DN', 1.0)
        end
      end
    end
  end
)

rspamd_config:register_symbol{
  name = 'REPLYTO_UNPARSEABLE',
  score = 1.0,
  parent = check_replyto_id,
  type = 'virtual',
  description = 'Reply-To header could not be parsed',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'HAS_REPLYTO',
  score = 0.0,
  parent = check_replyto_id,
  type = 'virtual',
  description = 'Has Reply-To header',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'REPLYTO_EQ_FROM',
  score = 0.0,
  parent = check_replyto_id,
  type = 'virtual',
  description = 'Reply-To header is identical to From header',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'REPLYTO_ADDR_EQ_FROM',
  score = 0.0,
  parent = check_replyto_id,
  type = 'virtual',
  description = 'Reply-To header is identical to SMTP From',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'REPLYTO_DOM_EQ_FROM_DOM',
  score = 0.0,
  parent = check_replyto_id,
  type = 'virtual',
  description = 'Reply-To domain matches the From domain',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'REPLYTO_DOM_NEQ_FROM_DOM',
  score = 0.0,
  parent = check_replyto_id,
  type = 'virtual',
  description = 'Reply-To domain does not match the From domain',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'REPLYTO_DN_EQ_FROM_DN',
  score = 0.0,
  parent = check_replyto_id,
  type = 'virtual',
  description = 'Reply-To display name matches From',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'REPLYTO_EMAIL_HAS_TITLE',
  score = 2.0,
  parent = check_replyto_id,
  type = 'virtual',
  description = 'Reply-To header has title',
  group = 'header',
}
rspamd_config:register_dependency(check_replyto_id, 'FROM_NAME_HAS_TITLE')

local check_mime_id = rspamd_config:register_symbol{
  name = 'CHECK_MIME',
  type = 'callback',
  callback = function(task)
    local parts = task:get_parts()
    if not parts then return false end

    -- Make sure there is a MIME-Version header
    local mv = task:get_header('MIME-Version')
    local missing_mime = false
    if (not mv) then
      missing_mime = true
    end

    local found_ma = false
    local found_plain = false
    local found_html = false
    local cte_7bit = false

    for _,p in ipairs(parts) do
      local mtype,subtype = p:get_type()
      local ctype = mtype:lower() .. '/' .. subtype:lower()
      if (ctype == 'multipart/alternative') then
        found_ma = true
      end
      if (ctype == 'text/plain') then
        if p:get_cte() == '7bit' then
          cte_7bit = true
        end
        found_plain = true
      end
      if (ctype == 'text/html') then
        if p:get_cte() == '7bit' then
          cte_7bit = true
        end
        found_html = true
      end
    end

    if missing_mime then
      if not (not found_ma and ((found_plain or found_html) and cte_7bit)) then
        task:insert_result('MISSING_MIME_VERSION', 1.0)
      end
    end

    if (found_ma) then
      if (not found_plain) then
        task:insert_result('MIME_MA_MISSING_TEXT', 1.0)
      end
      if (not found_html) then
        task:insert_result('MIME_MA_MISSING_HTML', 1.0)
      end
    end
  end
}

rspamd_config:register_symbol{
  name = 'MISSING_MIME_VERSION',
  score = 2.0,
  parent = check_mime_id,
  type = 'virtual',
  description = 'MIME-Version header is missing',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'MIME_MA_MISSING_TEXT',
  score = 2.0,
  parent = check_mime_id,
  type = 'virtual',
  description = 'MIME multipart/alternative missing text/plain part',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'MIME_MA_MISSING_HTML',
  score = 1.0,
  parent = check_mime_id,
  type = 'virtual',
  description = 'MIME multipart/alternative missing text/html part',
  group = 'header',
}

-- Used to be called IS_LIST
rspamd_config.PREVIOUSLY_DELIVERED = {
  callback = function(task)
    if not task:has_recipients(2) then return false end
    local to = task:get_recipients(2)
    local rcvds = task:get_header_full('Received')
    if not rcvds then return false end
    for _, rcvd in ipairs(rcvds) do
      local _,_,addr = rcvd['decoded']:lower():find("%sfor%s<(.-)>")
      if addr then
        for _, toa in ipairs(to) do
          if toa and toa.addr:lower() == addr then
            return true, addr
          end
        end
        return false
      end
    end
  end,
  description = 'Message either to a list or was forwarded',
  score = 0.0
}
rspamd_config.BROKEN_HEADERS = {
  callback = function(task)
    return task:has_flag('broken_headers')
  end,
  score = 10.0,
  group = 'header',
  description = 'Headers structure is likely broken'
}

rspamd_config.BROKEN_CONTENT_TYPE = {
  callback = function(task)
    return fun.any(function(p) return p:is_broken() end,
      task:get_parts())
  end,
  score = 1.5,
  group = 'header',
  description = 'Message has part with broken content type'
}

rspamd_config.HEADER_RCONFIRM_MISMATCH = {
  callback = function (task)
    local header_from = nil
    local cread = task:get_header('X-Confirm-Reading-To')

    if task:has_from('mime') then
      header_from  = task:get_from('mime')[1]
    end

    local header_cread = nil
    if cread then
      local headers_cread = util.parse_mail_address(cread)
      if headers_cread then header_cread = headers_cread[1] end
    end

    if header_from and header_cread then
      if not string.find(header_from['addr'], header_cread['addr']) then
        return true
      end
    end

    return false
  end,

  score = 2.0,
  group = 'header',
  description = 'Read confirmation address is different to from address'
}

rspamd_config.HEADER_FORGED_MDN = {
  callback = function (task)
    local mdn = task:get_header('Disposition-Notification-To')
    if not mdn then return false end
    local header_rp = nil

    if task:has_from('smtp') then
      header_rp = task:get_from('smtp')[1]
    end

    -- Parse mail addr
    local headers_mdn = util.parse_mail_address(mdn)

    if headers_mdn and not header_rp  then return true end
    if header_rp  and not headers_mdn then return false end
    if not headers_mdn and not header_rp then return false end

    local found_match = false
    for _, h in ipairs(headers_mdn) do
      if util.strequal_caseless(h['addr'], header_rp['addr']) then
        found_match = true
        break
      end
    end

    return (not found_match)
  end,

  score = 2.0,
  group = 'header',
  description = 'Read confirmation address is different to return path'
}

local headers_unique = {
  'Content-Type',
  'Content-Transfer-Encoding',
  -- https://tools.ietf.org/html/rfc5322#section-3.6
  'Date',
  'From',
  'Sender',
  'Reply-To',
  'To',
  'Cc',
  'Bcc',
  'Message-ID',
  'In-Reply-To',
  'References',
  'Subject'
}

rspamd_config.MULTIPLE_UNIQUE_HEADERS = {
  callback = function(task)
    local res = 0
    local res_tbl = {}

    for _,hdr in ipairs(headers_unique) do
      local h = task:get_header_full(hdr)

      if h and #h > 1 then
        res = res + 1
        table.insert(res_tbl, hdr)
      end
    end

    if res > 0 then
      return true,res,table.concat(res_tbl, ',')
    end

    return false
  end,

  score = 5.0,
  group = 'header',
  description = 'Repeated unique headers'
}

rspamd_config.MISSING_FROM = {
  callback = function(task)
    local from = task:get_header('From')
    if from == nil or from == '' then
      return true
    end
    return false
  end,
  score = 2.0,
  group = 'header',
  description = 'Missing From: header'
}
rspamd_config.MV_CASE = {
  callback = function (task)
    local mv = task:get_header('Mime-Version', true)
    if (mv) then return true end
  end,
  description = 'Mime-Version .vs. MIME-Version',
  score = 0.5
}

rspamd_config.FAKE_REPLY = {
  callback = function (task)
    local subject = task:get_header('Subject')
    if (subject and subject:lower():find('^re:')) then
      local ref = task:get_header('References')
      local rt  = task:get_header('In-Reply-To')
      if (not (ref or rt)) then return true end
    end
    return false
  end,
  description = 'Fake reply',
  score = 1.0
}

local check_from_id = rspamd_config:register_symbol{
  name = 'CHECK_FROM',
  type = 'callback',
  callback = function(task)
    local envfrom = task:get_from(1)
    local from = task:get_from(2)
    if (from and from[1] and not from[1].name) then
      task:insert_result('FROM_NO_DN', 1.0)
    elseif (from and from[1] and from[1].name and
            from[1].name:lower() == from[1].addr:lower()) then
      task:insert_result('FROM_DN_EQ_ADDR', 1.0)
    elseif (from and from[1] and from[1].name) then
      task:insert_result('FROM_HAS_DN', 1.0)
      -- Look for Mr/Mrs/Dr titles
      local n = from[1].name:lower()
      local match, match_end
      match, match_end = n:find('^mrs?[%.%s]')
      if match then
        task:insert_result('FROM_NAME_HAS_TITLE', 1.0, n:sub(match, match_end-1))
      end
      match, match_end = n:find('^dr[%.%s]')
      if match then
        task:insert_result('FROM_NAME_HAS_TITLE', 1.0, n:sub(match, match_end-1))
      end
      -- Check for excess spaces
      if n:find('%s%s') then
        task:insert_result('FROM_NAME_EXCESS_SPACE', 1.0)
      end
    end
    if (envfrom and from and envfrom[1] and from[1] and
        envfrom[1].addr:lower() == from[1].addr:lower())
    then
      task:insert_result('FROM_EQ_ENVFROM', 1.0)
    elseif (envfrom and envfrom[1] and envfrom[1].addr) then
      task:insert_result('FROM_NEQ_ENVFROM', 1.0, from and from[1].addr or '', envfrom[1].addr)
    end

    local to = task:get_recipients(2)
    if not (to and to[1] and #to == 1 and from) then return false end
    -- Check if FROM == TO
    if (to[1].addr:lower() == from[1].addr:lower()) then
      task:insert_result('TO_EQ_FROM', 1.0)
    elseif (to[1].domain and from[1].domain and
        to[1].domain:lower() == from[1].domain:lower()) then
      task:insert_result('TO_DOM_EQ_FROM_DOM', 1.0)
    end
  end
}

rspamd_config:register_symbol{
  name = 'FROM_NO_DN',
  score = 0,
  group = 'header',
  parent = check_from_id,
  type = 'virtual',
  description = 'From header does not have a display name',
}
rspamd_config:register_symbol{
  name = 'FROM_DN_EQ_ADDR',
  score = 1.0,
  group = 'header',
  parent = check_from_id,
  type = 'virtual',
  description = 'From header display name is the same as the address',
}
rspamd_config:register_symbol{
  name = 'FROM_HAS_DN',
  score = 0.0,
  group = 'header',
  parent = check_from_id,
  type = 'virtual',
  description = 'From header has a display name',
}
rspamd_config:register_symbol{
  name = 'FROM_NAME_EXCESS_SPACE',
  score = 1.0,
  group = 'header',
  parent = check_from_id,
  type = 'virtual',
  description = 'From header display name contains excess whitespace',
}
rspamd_config:register_symbol{
  name = 'FROM_NAME_HAS_TITLE',
  score = 1.0,
  group = 'header',
  parent = check_from_id,
  type = 'virtual',
  description = 'From header display name has a title (Mr/Mrs/Dr)',
}
rspamd_config:register_symbol{
  name = 'FROM_EQ_ENVFROM',
  score = 0.0,
  group = 'header',
  parent = check_from_id,
  type = 'virtual',
  description = 'From address is the same as the envelope',
}
rspamd_config:register_symbol{
  name = 'FROM_NEQ_ENVFROM',
  score = 0.0,
  group = 'header',
  parent = check_from_id,
  type = 'virtual',
  description = 'From address is different to the envelope',
}
rspamd_config:register_symbol{
  name = 'TO_EQ_FROM',
  score = 0.0,
  group = 'header',
  parent = check_from_id,
  type = 'virtual',
  description = 'To address matches the From address',
}
rspamd_config:register_symbol{
  name = 'TO_DOM_EQ_FROM_DOM',
  score = 0.0,
  group = 'header',
  parent = check_from_id,
  type = 'virtual',
  description = 'To domain is the same as the From domain',
}

local check_to_cc_id = rspamd_config:register_symbol{
  name = 'CHECK_TO_CC',
  type = 'callback',
  callback = function(task)
    local rcpts = task:get_recipients(1)
    local to = task:get_recipients(2)
    local to_match_envrcpt = 0
    local cnts = {
      [1] = 'ONE',
      [2] = 'TWO',
      [3] = 'THREE',
      [5] = 'FIVE',
      [7] = 'SEVEN',
      [12] = 'TWELVE',
      [50] = 'GT_50'
    }
    local def = 'ZERO'
    if (not to) then return false end
    -- Add symbol for recipient count
    local nrcpt = #to
    for k,v in pairs(cnts) do
      if nrcpt >= tonumber(k) then
        def = v
      end
    end
    task:insert_result('RCPT_COUNT_' .. def, 1.0, tostring(nrcpt))
    -- Check for display names
    local to_dn_count = 0
    local to_dn_eq_addr_count = 0
    for _, toa in ipairs(to) do
      -- To: Recipients <noreply@dropbox.com>
      if (toa['name'] and (toa['name']:lower() == 'recipient'
          or toa['name']:lower() == 'recipients')) then
        task:insert_result('TO_DN_RECIPIENTS', 1.0)
      end
      if (toa['name'] and toa['name']:lower() == toa['addr']:lower()) then
        to_dn_eq_addr_count = to_dn_eq_addr_count + 1
      elseif (toa['name']) then
        to_dn_count = to_dn_count + 1
      end
      -- See if header recipients match envrcpts
      if (rcpts) then
        for _, rcpt in ipairs(rcpts) do
          if (toa and toa['addr'] and rcpt and rcpt['addr'] and
              rcpt['addr']:lower() == toa['addr']:lower())
          then
            to_match_envrcpt = to_match_envrcpt + 1
          end
        end
      end
    end
    if (to_dn_count == 0 and to_dn_eq_addr_count == 0) then
      task:insert_result('TO_DN_NONE', 1.0)
    elseif (to_dn_count == #to) then
      task:insert_result('TO_DN_ALL', 1.0)
    elseif (to_dn_count > 0) then
      task:insert_result('TO_DN_SOME', 1.0)
    end
    if (to_dn_eq_addr_count == #to) then
      task:insert_result('TO_DN_EQ_ADDR_ALL', 1.0)
    elseif (to_dn_eq_addr_count > 0) then
      task:insert_result('TO_DN_EQ_ADDR_SOME', 1.0)
    end

    -- See if header recipients match envelope recipients
    if (to_match_envrcpt == #to) then
      task:insert_result('TO_MATCH_ENVRCPT_ALL', 1.0)
    elseif (to_match_envrcpt > 0) then
      task:insert_result('TO_MATCH_ENVRCPT_SOME', 1.0)
    end
  end
}

rspamd_config:register_symbol{
  name = 'RCPT_COUNT_ZERO',
  score = 0.0,
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'No recipients',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCPT_COUNT_ONE',
  score = 0.0,
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'One recipient',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCPT_COUNT_TWO',
  score = 0.0,
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'Two recipients',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCPT_COUNT_THREE',
  score = 0.0,
  parent = check_to_cc_id,
  type = 'virtual',
  description = '3-5 recipients',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCPT_COUNT_FIVE',
  score = 0.0,
  parent = check_to_cc_id,
  type = 'virtual',
  description = '5-7 recipients',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCPT_COUNT_SEVEN',
  score = 0.0,
  parent = check_to_cc_id,
  type = 'virtual',
  description = '7-11 recipients',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCPT_COUNT_TWELVE',
  score = 0.0,
  parent = check_to_cc_id,
  type = 'virtual',
  description = '12-50 recipients',
  group = 'header',
}
rspamd_config:register_symbol{
  name = 'RCPT_COUNT_GT_50',
  score = 0.0,
  parent = check_to_cc_id,
  type = 'virtual',
  description = '50+ recipients',
  group = 'header',
}

rspamd_config:register_symbol{
  name = 'TO_DN_RECIPIENTS',
  score = 2.0,
  group = 'header',
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'To header display name is "Recipients"',
}
rspamd_config:register_symbol{
  name = 'TO_DN_NONE',
  score = 0.0,
  group = 'header',
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'None of the recipients have display names',
}
rspamd_config:register_symbol{
  name = 'TO_DN_ALL',
  score = 0.0,
  group = 'header',
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'All the recipients have display names',
}
rspamd_config:register_symbol{
  name = 'TO_DN_SOME',
  score = 0.0,
  group = 'header',
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'Some of the recipients have display names',
}
rspamd_config:register_symbol{
  name = 'TO_DN_EQ_ADDR_ALL',
  score = 0.0,
  group = 'header',
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'All of the recipients have display names that are the same as their address',
}
rspamd_config:register_symbol{
  name = 'TO_DN_EQ_ADDR_SOME',
  score = 0.0,
  group = 'header',
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'Some of the recipients have display names that are the same as their address',
}
rspamd_config:register_symbol{
  name = 'TO_MATCH_ENVRCPT_ALL',
  score = 0.0,
  group = 'header',
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'All of the recipients match the envelope',
}
rspamd_config:register_symbol{
  name = 'TO_MATCH_ENVRCPT_SOME',
  score = 0.0,
  group = 'header',
  parent = check_to_cc_id,
  type = 'virtual',
  description = 'Some of the recipients match the envelope',
}