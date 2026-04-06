package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/openimsdk/open-im-server/v3/pkg/common/prommetrics"
	"github.com/openimsdk/tools/apiresp"
	"github.com/openimsdk/tools/discovery"
	"github.com/openimsdk/tools/errs"
)

type PrometheusDiscoveryApi struct {
	config *Config
	kv     discovery.KeyValue
}

func NewPrometheusDiscoveryApi(config *Config, client discovery.SvcDiscoveryRegistry) *PrometheusDiscoveryApi {
	api := &PrometheusDiscoveryApi{
		config: config,
		kv:     client,
	}
	return api
}

// discovery 用于根据指定 key，从注册中心获取并返回 Prometheus Target 信息。
// 如果注册中心不支持该操作，则返回空数组；
// 如果获取过程中出现错误，返回错误信息；
// 如果没有相关的 target 数据，也返回空的 target 数组；
// 最后，将所有目标和标签组装后以 JSON 格式返回。
func (p *PrometheusDiscoveryApi) discovery(c *gin.Context, key string) {
	// 从注册中心根据 key 前缀获取所有目标的值。
	value, err := p.kv.GetKeyWithPrefix(c, prommetrics.BuildDiscoveryKeyPrefix(key))
	if err != nil {
		// 如果注册中心不支持该操作，返回空数组。
		if errors.Is(err, discovery.ErrNotSupported) {
			c.JSON(http.StatusOK, []struct{}{})
			return
		}
		// 获取数据过程中发生其他错误，返回错误信息。
		apiresp.GinError(c, errs.WrapMsg(err, "get key value"))
		return
	}
	// 如果未获取到任何目标，返回空 Target 数组。
	if len(value) == 0 {
		c.JSON(http.StatusOK, []*prommetrics.RespTarget{})
		return
	}
	var resp prommetrics.RespTarget
	// 解析所有获取到的目标数据并组装成 Prometheus Target 格式。
	for i := range value {
		var tmp prommetrics.Target
		// 将获取到的字节流进行反序列化处理。
		if err = json.Unmarshal(value[i], &tmp); err != nil {
			apiresp.GinError(c, errs.WrapMsg(err, "json unmarshal err"))
			return
		}
		// 将目标地址添加到返回结构体中
		resp.Targets = append(resp.Targets, tmp.Target)
		// 标签使用注册时固定的默认标签，见 prommetrics.BuildDefaultTarget
		resp.Labels = tmp.Labels
	}
	// 返回组装好的目标信息数组（这里只有一个 resp）。
	c.JSON(http.StatusOK, []*prommetrics.RespTarget{&resp})
}

func (p *PrometheusDiscoveryApi) Api(c *gin.Context) {
	p.discovery(c, prommetrics.APIKeyName)
}

func (p *PrometheusDiscoveryApi) User(c *gin.Context) {
	p.discovery(c, p.config.Discovery.RpcService.User)
}

func (p *PrometheusDiscoveryApi) Group(c *gin.Context) {
	p.discovery(c, p.config.Discovery.RpcService.Group)
}

func (p *PrometheusDiscoveryApi) Msg(c *gin.Context) {
	p.discovery(c, p.config.Discovery.RpcService.Msg)
}

func (p *PrometheusDiscoveryApi) Friend(c *gin.Context) {
	p.discovery(c, p.config.Discovery.RpcService.Friend)
}

func (p *PrometheusDiscoveryApi) Conversation(c *gin.Context) {
	p.discovery(c, p.config.Discovery.RpcService.Conversation)
}

func (p *PrometheusDiscoveryApi) Third(c *gin.Context) {
	p.discovery(c, p.config.Discovery.RpcService.Third)
}

func (p *PrometheusDiscoveryApi) Auth(c *gin.Context) {
	p.discovery(c, p.config.Discovery.RpcService.Auth)
}

func (p *PrometheusDiscoveryApi) Push(c *gin.Context) {
	p.discovery(c, p.config.Discovery.RpcService.Push)
}

func (p *PrometheusDiscoveryApi) MessageGateway(c *gin.Context) {
	p.discovery(c, p.config.Discovery.RpcService.MessageGateway)
}

func (p *PrometheusDiscoveryApi) MessageTransfer(c *gin.Context) {
	p.discovery(c, prommetrics.MessageTransferKeyName)
}
