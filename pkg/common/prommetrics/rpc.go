package prommetrics

import (
	"net"
	"strconv"

	gp "github.com/grpc-ecosystem/go-grpc-prometheus"
	"github.com/openimsdk/open-im-server/v3/pkg/common/config"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const rpcPath = commonPath

var (
	grpcMetrics *gp.ServerMetrics
	rpcCounter  = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "rpc_count",
			Help: "Total number of RPC calls",
		},
		[]string{"name", "path", "code"},
	)
)

func RegistryRpc() {
	registry.MustRegister(rpcCounter)
}

func RpcInit(cs []prometheus.Collector, listener net.Listener) error {
	reg := prometheus.NewRegistry()
	cs = append(append(
		baseCollector,
		rpcCounter,
	), cs...)
	return Init(reg, listener, rpcPath, promhttp.HandlerFor(reg, promhttp.HandlerOpts{Registry: reg}), cs...)
}

func RPCCall(name string, path string, code int) {
	rpcCounter.With(prometheus.Labels{"name": name, "path": path, "code": strconv.Itoa(code)}).Inc()
}

func GetGrpcServerMetrics() *gp.ServerMetrics {
	if grpcMetrics == nil {
		grpcMetrics = gp.NewServerMetrics()
		grpcMetrics.EnableHandlingTimeHistogram()
	}
	return grpcMetrics
}

// 根据不同的registerName，返回对应的prometheus指标收集器
func GetGrpcCusMetrics(registerName string, discovery *config.Discovery) []prometheus.Collector {
	switch registerName {
	case discovery.RpcService.MessageGateway:
		// 消息网关服务，返回在线用户统计指标
		return []prometheus.Collector{OnlineUserGauge}
	case discovery.RpcService.Msg:
		// 消息服务，返回单聊和群聊消息处理成功/失败统计指标
		return []prometheus.Collector{
			SingleChatMsgProcessSuccessCounter,
			SingleChatMsgProcessFailedCounter,
			GroupChatMsgProcessSuccessCounter,
			GroupChatMsgProcessFailedCounter,
		}
	case discovery.RpcService.Push:
		return []prometheus.Collector{
			MsgOfflinePushFailedCounter,
			MsgLoneTimePushCounter,
		}
	case discovery.RpcService.Auth:
		return []prometheus.Collector{UserLoginCounter}
	case discovery.RpcService.User:
		return []prometheus.Collector{UserRegisterCounter}
	default:
		return nil
	}
}
