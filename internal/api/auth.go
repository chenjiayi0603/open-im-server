// Copyright © 2023 OpenIM. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package api

import (
	"net/http"
	"net/netip"

	"github.com/gin-gonic/gin"
	"github.com/openimsdk/protocol/auth"
	"github.com/openimsdk/tools/a2r"
)

type AuthApi struct {
	Client auth.AuthClient
}

func NewAuthApi(client auth.AuthClient) AuthApi {
	return AuthApi{client}
}

// RestrictAdminTokenEndpoint blocks public network requests for admin token minting.
func RestrictAdminTokenEndpoint() gin.HandlerFunc {
	return func(c *gin.Context) {
		ip := c.ClientIP()
		addr, err := netip.ParseAddr(ip)
		if err != nil || !(addr.IsLoopback() || addr.IsPrivate() || addr.IsLinkLocalUnicast()) {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{
				"errCode": http.StatusForbidden,
				"errMsg":  "forbidden",
				"errDlt":  "get_admin_token is restricted to internal network",
			})
			return
		}
		c.Next()
	}
}

func (o *AuthApi) GetAdminToken(c *gin.Context) {
	a2r.Call(c, auth.AuthClient.GetAdminToken, o.Client)
}

func (o *AuthApi) GetUserToken(c *gin.Context) {
	a2r.Call(c, auth.AuthClient.GetUserToken, o.Client)
}

func (o *AuthApi) ParseToken(c *gin.Context) {
	a2r.Call(c, auth.AuthClient.ParseToken, o.Client)
}

func (o *AuthApi) ForceLogout(c *gin.Context) {
	a2r.Call(c, auth.AuthClient.ForceLogout, o.Client)
}
