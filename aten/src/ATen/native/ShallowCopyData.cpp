#include <ATen/ATen.h>
#include <ATen/FunctionalTensorWrapper.h>
#include <torch/library.h>

namespace at::native {

static at::Tensor& shallow_copy_data_(
    at::Tensor& self,
    const at::Tensor& source) {
  // Mirror the safety checks from VariableHooks::set_data
  // (torch/csrc/autograd/variable.cpp) so that calling this op
  // directly enforces the same invariants as eager .data = .
  TORCH_CHECK(
      at::_has_compatible_shallow_copy_type(self, source),
      "shallow_copy_data_: self and source have incompatible tensor type");

  TORCH_CHECK(
      !self.requires_grad() ||
          at::isFloatingType(source.scalar_type()) ||
          at::isComplexType(source.scalar_type()),
      "shallow_copy_data_: data set to a tensor that requires gradients "
      "must be floating point or complex dtype");

  if (self.unsafeGetTensorImpl() != source.unsafeGetTensorImpl()) {
    self.unsafeGetTensorImpl()->shallow_copy_from(source.getIntrusivePtr());
  }
  return self;
}

static at::Tensor& shallow_copy_data_functionalize(
    at::Tensor& self,
    const at::Tensor& src) {
  TORCH_CHECK(
      at::functionalization::impl::isFunctionalTensor(self) ||
          !at::functionalization::impl::isFunctionalTensor(src),
      "shallow_copy_data_: cannot mutate a non-functional tensor with a functional tensor");

  // Non-functional path: redispatch through the op schema so
  // ProxyTorchDispatch can record an FX node during make_fx tracing.
  if (!at::functionalization::impl::isFunctionalTensor(self) &&
      !at::functionalization::impl::isFunctionalTensor(src)) {
    at::AutoDispatchSkipFunctionalize guard;
    static auto op = c10::Dispatcher::singleton()
                         .findSchemaOrThrow("aten::shallow_copy_data_", "")
                         .typed<at::Tensor&(at::Tensor&, const at::Tensor&)>();
    return op.call(self, src);
  }

  TORCH_CHECK(
      at::functionalization::impl::isFunctionalTensor(src),
      "shallow_copy_data_: source must be a FunctionalTensor");

  auto self_impl =
      at::functionalization::impl::unsafeGetFunctionalWrapper(self);
  auto src_impl =
      at::functionalization::impl::unsafeGetFunctionalWrapper(src);
  TORCH_CHECK(
      !self_impl->was_inductor_storage_resized(),
      "storage_resize_() followed by shallow_copy_data_() is not supported");
  self_impl->set__impl(src_impl);
  return self;
}

TORCH_LIBRARY_FRAGMENT(aten, m) {
  m.def("shallow_copy_data_(Tensor(a!) self, Tensor source) -> Tensor(a!)");
}

TORCH_LIBRARY_IMPL(aten, CompositeExplicitAutograd, m) {
  m.impl("shallow_copy_data_", shallow_copy_data_);
}

TORCH_LIBRARY_IMPL(aten, Functionalize, m) {
  m.impl("shallow_copy_data_", shallow_copy_data_functionalize);
}

} // namespace at::native
