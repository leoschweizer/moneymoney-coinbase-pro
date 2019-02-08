-- Inofficial Coinbase Pro Extension (https://pro.coinbase.com/) for MoneyMoney
-- Fetches balances via Coinbase Pro API and returns them as securities
--
-- Username: Coinbase Pro API Key
-- Username2: Coinbase Pro API Secret
-- Password: Coinbase Pro API Passphrase
--
-- Copyright (c) 2017 Leo Schweizer
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

WebBanking {
        version = 2.0,
        url = "https://api.pro.coinbase.com",
        description = "Fetch balances via Coinbase Pro API and list them as securities",
        services = { "Coinbase Pro" }
}

local apiKey
local apiSecret
local apiPassphrase

local nativeCurrency = "EUR"
local market = "Coinbase Pro"

function SupportsBank (protocol, bankCode)
        return protocol == ProtocolWebBanking and bankCode == "Coinbase Pro"
end

function InitializeSession (protocol, bankCode, username, username2, password, username3)
        apiKey = username
        apiSecret = username2
        apiPassphrase = password
end

function ListAccounts (knownAccounts)
        local account = {
                name = market,
                accountNumber = "Main",
                currency = nativeCurrency,
                portfolio = true,
                type = "AccountTypePortfolio"
        }
        return {account}
end

function RefreshAccount (account, since)
        local s = {}
        local balances = queryCoinbaseProApi("accounts")
        local products = queryCoinbaseProApi("products")
        for _, balance_data in pairs(balances) do
                local after = nil
                local crypo_shorthandle = balance_data["currency"]
                local total_quantity = tonumber(balance_data["balance"])
                local price = 1
                local product_id = crypo_shorthandle .. "-" .. nativeCurrency
                local amount = nil
                local quantity = nil
                local currency = nil
                local order_value = 0.0
                local timestamp = nil
                local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+).%d+Z"

                if crypo_shorthandle ~= nativeCurrency and productsExists(product_id, products) then
                        price = queryExchangeRate(product_id, products)
                        -- Fetch pages of 100 orders for this currency, these are based on trades on Coinbase Pro
                        after = "start"
                        -- Iterate through pages until cb-after header is unset
                        while after ~= nil do
                                if after == "start" then
                                        orders, headers = queryCoinbaseProApi("orders?&status=done&&product_id=" .. product_id)
                                else
                                        orders, headers = queryCoinbaseProApi("orders?after=" .. after .. "&status=done&product_id=" .. product_id)
                                end
                                -- Set our next page to cb-after header
                                after = headers["cb-after"]

                                -- Iterate through this page of orders
                                for _, order_data in pairs(orders) do
                                        -- We only care of buy, sold coins will not be in our balance anymore
                                        if order_data["side"] == "buy" then
                                                year, month, day, hour, min, sec = order_data["done_at"]:match(pattern)
                                                timestamp = os.time({day=day,month=month,year=year,hour=hour,min=min,sec=sec})
                                                quantity = order_data["filled_size"]
                                                -- We deduct our trade from the total amount
                                                total_quantity = total_quantity - quantity
                                                if order_data["price"] ~= nil then
                                                        order_value = order_data["price"]
                                                else
                                                        order_value = 1 / order_data["filled_size"] * order_data["executed_value"]
                                                end
                                                s[#s+1] = {
                                                        tradeTimestamp = timestamp,
                                                        name = crypo_shorthandle,
                                                        market = market,
                                                        quantity = quantity,
                                                        currency = currency,
                                                        price = price,
                                                        purchasePrice = order_value,
                                                        amount = quantity * price
                                                }
                                        end
                                end
                        end
                        -- Sums for the remaining coins not in the order book
                        quantity = total_quantity
                        amount = total_quantity * price
                else
                        -- A native currency, not a crypto coin
                        quantity = nil
                        price = nil
                        currency = nativeCurrency
                        amount = total_quantity
                end
                -- We also have to add our remaining total amount that is not part of trades
                -- Could come from deposits of other accounts, there will be no value attached to the transfer
                -- Only add them if we have some left after removing trades
                if total_quantity > 0 then
                        s[#s+1] = {
                                name = crypo_shorthandle,
                                market = market,
                                currency = currency,
                                quantity = quantity,
                                price = price,
                                amount = amount
                        }
                end
        end
        return {securities = s}
end

function EndSession ()
end

function base64decode(data)
        local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        data = string.gsub(data, '[^'..b..'=]', '')
        return (data:gsub('.', function(x)
                if (x == '=') then return '' end
                local r,f='',(b:find(x)-1)
                for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
                return r;
        end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
                if (#x ~= 8) then return '' end
                local c=0
                for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
                return string.char(c)
        end))
end

function queryCoinbaseProApi(endpoint)
        -- try not to run into `too many requests`, pause before each
        sleep(1)
        local path = string.format("/%s", endpoint)
        local timestamp = string.format("%d", MM.time())
        local apiSign = MM.hmac256(base64decode(apiSecret), timestamp .. "GET" .. path)

        local headers = {}
        headers["CB-ACCESS-KEY"] = apiKey
        headers["CB-ACCESS-TIMESTAMP"] = timestamp
        headers["CB-ACCESS-SIGN"] = MM.base64(apiSign)
        headers["CB-ACCESS-PASSPHRASE"] = apiPassphrase

        content, charset, mimeType, filename, rem_headers = Connection():request("GET", url .. path, nil, nil, headers)
        return JSON(content):dictionary(), rem_headers
end

function queryExchangeRate(product_id, products)
        return queryCoinbaseProApi("products/" .. product_id .. "/ticker")["price"]
end

function productsExists(product_id, products)
        for _, data in pairs(products) do
                if data["id"] == product_id then return true end
        end
        return false
end

local clock = os.clock
function sleep(n)  -- seconds
  local t0 = clock()
  while clock() - t0 <= n do end
end
-- SIGNATURE: MC0CFEG8subcDGgx/zTD7J/1tZqFZzwHAhUAml+4P1Ykr5zy+8ZerTz6I4AKsqQ=
